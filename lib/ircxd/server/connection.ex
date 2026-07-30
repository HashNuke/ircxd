defmodule Ircxd.Server.Connection do
  @moduledoc false

  use GenServer

  alias Ircxd.Message

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)
    transport = Keyword.get(opts, :transport, :gen_tcp)
    registration_timeout = Keyword.get(opts, :registration_timeout, 60_000)

    {:ok,
     %{
       socket: socket,
       transport: transport,
       server: Keyword.fetch!(opts, :server),
       server_name: Keyword.fetch!(opts, :server_name),
       isupport: Keyword.fetch!(opts, :isupport),
       capabilities: Keyword.fetch!(opts, :capabilities),
       active_capabilities: MapSet.new(),
       password: Keyword.get(opts, :password),
       password_authenticated?: is_nil(Keyword.get(opts, :password)),
       allow_insecure_auth?: Keyword.get(opts, :allow_insecure_auth?, false),
       registration_timer: registration_timer(registration_timeout),
       command_rate_limit: Keyword.get(opts, :command_rate_limit, 100),
       command_window_started: System.monotonic_time(:millisecond),
       command_count: 0,
       auth_required?: Keyword.get(opts, :auth_required?, false),
       external_auth?: Keyword.get(opts, :external_auth?, false),
       peer: nil,
       peer_certificate: nil,
       peer_certificate_sha256: nil,
       sasl_mechanism: nil,
       authenticated?: false,
       account: nil,
       nick: nil,
       username: nil,
       realname: nil,
       registered?: false
     }}
  end

  @impl true
  def handle_info(:activate, state) do
    :ok = setopts(state.transport, state.socket, active: :once)
    {:noreply, put_connection_security(state)}
  end

  def handle_info({:server_send, %Message{} = message}, state) do
    message = outbound_message(state, message)

    case send_data(state.transport, state.socket, Message.serialize(message)) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    handle_active_line(line, state)
  end

  def handle_info({:ssl, socket, line}, %{socket: socket} = state) do
    handle_active_line(line, state)
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, reason, state}
  def handle_info({:ssl_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:ssl_error, _socket, reason}, state), do: {:stop, reason, state}

  def handle_info(:registration_timeout, %{registered?: false} = state) do
    send_message(state, "ERROR", ["Registration timeout"])
    {:stop, :normal, state}
  end

  def handle_info(:registration_timeout, state), do: {:noreply, state}

  defp handle_active_line(line, state) do
    case consume_command_quota(state) do
      {:ok, state} ->
        case Message.parse(line) do
          {:ok, message} ->
            message
            |> handle_message(state)
            |> reactivate_socket()

          {:error, reason} when reason in [:line_too_long, :tag_section_too_long] ->
            send_message(state, "417", [state.nick || "*", "Input line too long"])
            reactivate_socket({:noreply, state})

          {:error, _reason} ->
            reactivate_socket({:noreply, state})
        end

      {:error, :rate_limited, state} ->
        send_message(state, "ERROR", ["Excess flood"])
        {:stop, :normal, state}
    end
  end

  defp reactivate_socket({:noreply, state}) do
    case setopts(state.transport, state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp reactivate_socket(other), do: other

  defp consume_command_quota(%{command_rate_limit: :infinity} = state), do: {:ok, state}

  defp consume_command_quota(state) do
    now = System.monotonic_time(:millisecond)

    state =
      if now - state.command_window_started >= 1_000 do
        %{state | command_window_started: now, command_count: 0}
      else
        state
      end

    if state.command_count < state.command_rate_limit do
      {:ok, %{state | command_count: state.command_count + 1}}
    else
      {:error, :rate_limited, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_socket(state.transport, state.socket)
  catch
    :error, :closed -> :ok
  end

  defp handle_message(%Message{command: "CAP", params: ["LS" | _]}, state) do
    caps = Enum.join(state.capabilities, " ")
    send_message(state, "CAP", ["*", "LS", caps])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "CAP", params: ["LIST" | _]}, state) do
    caps = state.active_capabilities |> MapSet.to_list() |> Enum.sort() |> Enum.join(" ")
    send_message(state, "CAP", ["*", "LIST", caps])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "CAP", params: ["END" | _]}, state),
    do: {:noreply, state}

  defp handle_message(%Message{command: "CAP", params: ["REQ"]}, state) do
    send_message(state, "461", [state.nick || "*", "CAP", "Not enough parameters"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "CAP", params: ["REQ", caps]}, state) do
    requested = String.split(caps, " ", trim: true)
    requests = Enum.map(requested, &capability_request/1)

    cond do
      requested == [] ->
        send_message(state, "CAP", ["*", "NAK", ""])
        {:noreply, state}

      Enum.all?(requests, fn {_action, capability} -> capability in state.capabilities end) ->
        send_message(state, "CAP", ["*", "ACK", Enum.join(requested, " ")])

        active_capabilities =
          Enum.reduce(requests, state.active_capabilities, fn
            {:enable, capability}, active -> MapSet.put(active, capability)
            {:disable, capability}, active -> MapSet.delete(active, capability)
          end)

        Ircxd.Server.capabilities(state.server, self(), active_capabilities)

        {:noreply, %{state | active_capabilities: active_capabilities}}

      true ->
        send_message(state, "CAP", ["*", "NAK", Enum.join(requested, " ")])
        {:noreply, state}
    end
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["PLAIN"]}, state)
       when state.auth_required? and
              (state.transport == :ssl or state.allow_insecure_auth?) do
    send_message(state, "AUTHENTICATE", ["+"])
    {:noreply, %{state | sasl_mechanism: :plain}}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["PLAIN"]}, state)
       when state.auth_required? do
    send_message(state, "904", [
      state.nick || "*",
      "Insecure authentication is disabled"
    ])

    {:noreply, %{state | sasl_mechanism: nil}}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: [mechanism]}, state)
       when not state.auth_required? and mechanism in ["PLAIN", "EXTERNAL"] do
    send_message(state, "904", [state.nick || "*", "SASL authentication unavailable"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}, state)
       when state.auth_required? and state.external_auth? and state.transport == :ssl and
              not is_nil(state.peer_certificate) do
    send_message(state, "AUTHENTICATE", ["+"])
    {:noreply, %{state | sasl_mechanism: :external}}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}, state)
       when state.auth_required? do
    send_message(state, "904", [
      state.nick || "*",
      "SASL EXTERNAL requires a verified TLS client certificate"
    ])

    {:noreply, %{state | sasl_mechanism: nil}}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["*"]}, state)
       when state.auth_required? do
    send_message(state, "906", [state.nick || "*", "SASL authentication aborted"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: [mechanism]}, state)
       when state.auth_required? and state.sasl_mechanism == nil and
              mechanism not in ["PLAIN", "EXTERNAL", "*"] do
    send_message(state, "904", [state.nick || "*", "Unsupported SASL mechanism"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: []}, state) do
    send_message(state, "461", [state.nick || "*", "AUTHENTICATE", "Not enough parameters"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: [payload]}, state)
       when state.auth_required? and state.sasl_mechanism == :external do
    case decode_external(payload) do
      {:ok, authzid} -> authenticate_credentials(state, authzid, "", :external)
      :error -> send_message(state, "904", [state.nick, "Invalid SASL credentials"])
    end
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: [payload]}, state)
       when state.auth_required? do
    case decode_plain(payload) do
      {:ok, username, password} ->
        authenticate_credentials(state, username, password, :plain)

      :error ->
        send_message(state, "904", [state.nick, "Invalid SASL credentials"])
        {:noreply, state}
    end
  end

  defp handle_message(%Message{command: "PASS", params: [_password]}, state)
       when state.transport != :ssl and not state.allow_insecure_auth? do
    send_message(state, "464", [state.nick || "*", "Insecure authentication is disabled"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "PASS", params: [password]}, state) do
    case Ircxd.Server.verify_password(state.server, password) do
      :ok ->
        maybe_register(%{state | password_authenticated?: true})

      {:error, :invalid_password} ->
        send_message(state, "464", [state.nick || "*", "Password incorrect"])
        {:noreply, state}
    end
  end

  defp handle_message(%Message{command: "PASS", params: []}, state) do
    send_message(state, "461", [state.nick || "*", "PASS", "Not enough parameters"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "NICK", params: []}, state) do
    send_message(state, "431", [state.nick || "*", "No nickname given"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "NICK", params: [nick]}, state) do
    cond do
      state.registered? ->
        if valid_nick?(nick) do
          case Ircxd.Server.change_nick(state.server, self(), nick) do
            :ok ->
              {:noreply, %{state | nick: nick}}

            {:error, :nick_in_use} ->
              send_message(state, "433", [state.nick, nick, "Nickname is already in use"])
              {:noreply, state}
          end
        else
          send_message(state, "432", [state.nick || "*", nick, "Erroneous nickname"])
          {:noreply, state}
        end

      valid_nick?(nick) ->
        maybe_register(%{state | nick: nick})

      true ->
        send_message(state, "432", [state.nick || "*", nick, "Erroneous nickname"])
        {:noreply, state}
    end
  end

  defp handle_message(%Message{command: "USER"}, %{registered?: true} = state) do
    send_message(state, "462", [state.nick || "*", "You may not reregister"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "USER", params: params}, state)
       when length(params) < 4 do
    send_message(state, "461", [state.nick || "*", "USER", "Not enough parameters"])
    {:noreply, state}
  end

  defp handle_message(
         %Message{command: "USER", params: [username, _mode, _unused, realname]},
         state
       ) do
    state = %{state | username: username, realname: realname}
    Ircxd.Server.identity(state.server, self(), username, realname)
    maybe_register(state)
  end

  defp handle_message(%Message{command: "PING", params: []}, state) do
    send_message(state, "461", [state.nick || "*", "PING", "Not enough parameters"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "PING", params: params, tags: tags}, state) do
    response = %Message{tags: Map.take(tags, ["label"]), command: "PONG", params: params}
    send_message(state, response)
    {:noreply, state}
  end

  defp handle_message(%Message{command: "PONG"}, state), do: {:noreply, state}

  defp handle_message(%Message{command: command} = message, state)
       when command in [
              "JOIN",
              "NAMES",
              "PART",
              "PRIVMSG",
              "NOTICE",
              "TAGMSG",
              "TOPIC",
              "MODE",
              "LIST",
              "MOTD",
              "LUSERS",
              "VERSION",
              "TIME",
              "ADMIN",
              "WHO",
              "WHOIS",
              "SETNAME"
            ] do
    Ircxd.Server.command(state.server, self(), message)
    {:noreply, state}
  end

  defp handle_message(%Message{command: "QUIT"} = message, state) do
    Ircxd.Server.command(state.server, self(), message)
    {:stop, :normal, state}
  end

  defp handle_message(%Message{} = message, state) do
    Ircxd.Server.command(state.server, self(), message)
    {:noreply, state}
  end

  defp capability_request("-" <> capability), do: {:disable, capability}
  defp capability_request(capability), do: {:enable, capability}

  defp maybe_register(%{registered?: true} = state), do: {:noreply, state}

  defp maybe_register(%{auth_required?: true, authenticated?: false} = state),
    do: {:noreply, state}

  defp maybe_register(%{password_authenticated?: false} = state), do: {:noreply, state}

  defp maybe_register(%{nick: nick, username: username} = state)
       when is_binary(nick) and is_binary(username) do
    case Ircxd.Server.register(state.server, self(), nick) do
      :ok ->
        send_message(state, "001", [nick, "Welcome to Ircxd"])
        send_message(state, "002", [nick, "Your host is #{state.server_name}"])

        send_message(
          state,
          "005",
          [nick | state.isupport] ++ ["are supported by this server"]
        )

        cancel_registration_timer(state)
        {:noreply, %{state | registered?: true, registration_timer: nil}}

      {:error, :nick_in_use} ->
        send_message(state, "433", [nick, nick, "Nickname is already in use"])
        {:noreply, state}
    end
  end

  defp maybe_register(state), do: {:noreply, state}

  defp valid_nick?(nick) when is_binary(nick) do
    String.match?(nick, ~r/\A[A-Za-z\[\]\\\^`{}|][A-Za-z0-9\-\[\]\\\^`{}|]{0,29}\z/)
  end

  defp valid_nick?(_nick), do: false

  defp registration_timer(timeout) when is_integer(timeout) and timeout > 0,
    do: Process.send_after(self(), :registration_timeout, timeout)

  defp registration_timer(_timeout), do: nil

  defp cancel_registration_timer(%{registration_timer: nil}), do: :ok
  defp cancel_registration_timer(%{registration_timer: timer}), do: Process.cancel_timer(timer)

  defp send_message(state, command, params),
    do: send_message(state, %Message{command: command, params: params})

  defp send_message(state, %Message{} = message) do
    message = outbound_message(state, message)
    metadata = %{server: state.server_name, connection: self(), nick: state.nick}
    Ircxd.Server.publish(state.server, message, metadata)
    send_data(state.transport, state.socket, Message.serialize(message))
  end

  defp setopts(:gen_tcp, socket, options), do: :inet.setopts(socket, options)
  defp setopts(:ssl, socket, options), do: :ssl.setopts(socket, options)

  defp send_data(:gen_tcp, socket, data), do: :gen_tcp.send(socket, data)
  defp send_data(:ssl, socket, data), do: :ssl.send(socket, data)

  defp close_socket(:gen_tcp, socket), do: :gen_tcp.close(socket)
  defp close_socket(:ssl, socket), do: :ssl.close(socket)

  defp add_server_time(%Message{} = message, state) do
    if MapSet.member?(state.active_capabilities, "server-time") do
      %{message | tags: Map.put_new(message.tags, "time", server_time())}
    else
      message
    end
  end

  defp outbound_message(state, %Message{} = message) do
    message
    |> add_message_id(state)
    |> add_server_time(state)
    |> filter_tags(state)
    |> filter_account_tag(state)
    |> filter_extended_join(state)
  end

  defp add_message_id(%Message{} = message, state) do
    if MapSet.member?(state.active_capabilities, "message-tags") and
         not Map.has_key?(message.tags, "msgid") do
      %{message | tags: Map.put(message.tags, "msgid", local_message_id())}
    else
      message
    end
  end

  defp local_message_id do
    :erlang.unique_integer([:positive]) |> Integer.to_string(16) |> String.upcase()
  end

  defp filter_tags(message, state) do
    if MapSet.member?(state.active_capabilities, "message-tags") or
         MapSet.member?(state.active_capabilities, "account-tag") or
         MapSet.member?(state.active_capabilities, "server-time") or
         MapSet.member?(state.active_capabilities, "labeled-response") do
      message
    else
      %{message | tags: %{}}
    end
  end

  defp filter_account_tag(message, state) do
    if MapSet.member?(state.active_capabilities, "account-tag"),
      do: message,
      else: %{message | tags: Map.delete(message.tags, "account")}
  end

  defp filter_extended_join(
         %Message{command: "JOIN", params: [channel, _account, _realname]} = message,
         state
       ) do
    if MapSet.member?(state.active_capabilities, "extended-join") do
      message
    else
      %{message | params: [channel]}
    end
  end

  defp filter_extended_join(message, _state), do: message

  defp server_time do
    DateTime.utc_now()
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp decode_plain(payload) do
    with {:ok, decoded} <- Base.decode64(payload),
         [_, username, password] <- String.split(decoded, <<0>>, parts: 3) do
      {:ok, username, password}
    else
      _ -> :error
    end
  end

  defp decode_external("+"), do: {:ok, ""}

  defp decode_external(payload) do
    case Base.decode64(payload) do
      {:ok, authzid} -> {:ok, authzid}
      :error -> :error
    end
  end

  defp authenticate_credentials(state, username, password, mechanism) do
    metadata = %{
      server: state.server_name,
      connection: self(),
      nick: state.nick,
      mechanism: mechanism,
      transport: state.transport,
      tls?: state.transport == :ssl,
      peer: state.peer,
      peer_certificate: state.peer_certificate,
      peer_certificate_sha256: state.peer_certificate_sha256
    }

    case Ircxd.Server.authenticate(state.server, username, password, metadata) do
      {:ok, account} ->
        userhost = "#{state.nick || "*"}!#{state.username || "user"}@#{state.server_name}"

        send_message(
          state,
          "900",
          [state.nick || "*", userhost, format_account(account), "You are now logged in"]
        )

        send_message(state, "903", [state.nick, "SASL authentication successful"])
        maybe_register(%{state | authenticated?: true, account: account, sasl_mechanism: nil})

      {:error, _reason} ->
        send_message(state, "904", [state.nick, "SASL authentication failed"])
        {:noreply, %{state | sasl_mechanism: nil}}
    end
  end

  defp format_account(account) when is_binary(account), do: account
  defp format_account(account), do: to_string(account)

  defp put_connection_security(state) do
    peer =
      case peername(state.transport, state.socket) do
        {:ok, peer} -> peer
        {:error, _reason} -> nil
      end

    certificate =
      case state.transport do
        :ssl ->
          case :ssl.peercert(state.socket) do
            {:ok, certificate} -> certificate
            {:error, _reason} -> nil
          end

        :gen_tcp ->
          nil
      end

    fingerprint =
      if is_binary(certificate) do
        certificate
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
      end

    %{state | peer: peer, peer_certificate: certificate, peer_certificate_sha256: fingerprint}
  end

  defp peername(:gen_tcp, socket), do: :inet.peername(socket)
  defp peername(:ssl, socket), do: :ssl.peername(socket)
end
