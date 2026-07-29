defmodule Ircxd.Server.Connection do
  @moduledoc false

  use GenServer

  alias Ircxd.Message

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)
    registration_timeout = Keyword.get(opts, :registration_timeout, 60_000)

    {:ok,
     %{
       socket: socket,
       server: Keyword.fetch!(opts, :server),
       server_name: Keyword.fetch!(opts, :server_name),
       isupport: Keyword.fetch!(opts, :isupport),
       capabilities: Keyword.fetch!(opts, :capabilities),
       active_capabilities: MapSet.new(),
       password: Keyword.get(opts, :password),
       password_authenticated?: is_nil(Keyword.get(opts, :password)),
       registration_timer: registration_timer(registration_timeout),
       auth_required?: Keyword.get(opts, :auth_required?, false),
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
    :ok = :inet.setopts(state.socket, active: true)
    {:noreply, state}
  end

  def handle_info({:server_send, %Message{} = message}, state) do
    message = outbound_message(state, message)

    case :gen_tcp.send(state.socket, Message.serialize(message)) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    case Message.parse(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, reason} when reason in [:line_too_long, :tag_section_too_long] ->
        send_message(state, "417", [state.nick || "*", "Input line too long"])
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, reason, state}

  def handle_info(:registration_timeout, %{registered?: false} = state) do
    send_message(state, "ERROR", ["Registration timeout"])
    {:stop, :normal, state}
  end

  def handle_info(:registration_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
  catch
    :error, :closed -> :ok
  end

  defp handle_message(%Message{command: "CAP", params: ["LS" | _]}, state) do
    caps = Enum.join(state.capabilities, " ")
    send_message(state, "CAP", ["*", "LS", caps])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "CAP", params: ["END" | _]}, state),
    do: {:noreply, state}

  defp handle_message(%Message{command: "CAP", params: ["REQ", caps]}, state) do
    requested = String.split(caps, " ", trim: true)

    cond do
      requested == [] ->
        send_message(state, "CAP", ["*", "NAK", ""])

      Enum.all?(requested, &(&1 in state.capabilities)) ->
        send_message(state, "CAP", ["*", "ACK", Enum.join(requested, " ")])

        active_capabilities = MapSet.union(state.active_capabilities, MapSet.new(requested))
        Ircxd.Server.capabilities(state.server, self(), active_capabilities)

        {:noreply, %{state | active_capabilities: active_capabilities}}

      true ->
        send_message(state, "CAP", ["*", "NAK", Enum.join(requested, " ")])
        {:noreply, state}
    end
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["PLAIN"]}, state) do
    send_message(state, "AUTHENTICATE", ["+"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: [payload]}, state)
       when state.auth_required? do
    case decode_plain(payload) do
      {:ok, username, password} ->
        metadata = %{server: state.server_name, connection: self(), nick: state.nick}

        case Ircxd.Server.authenticate(state.server, username, password, metadata) do
          {:ok, account} ->
            userhost = "#{state.nick || "*"}!#{state.username || "user"}@#{state.server_name}"

            send_message(
              state,
              "900",
              [state.nick || "*", userhost, format_account(account), "You are now logged in"]
            )

            send_message(state, "903", [state.nick, "SASL authentication successful"])
            maybe_register(%{state | authenticated?: true, account: account})

          {:error, _reason} ->
            send_message(state, "904", [state.nick, "SASL authentication failed"])
            {:noreply, state}
        end

      :error ->
        send_message(state, "904", [state.nick, "Invalid SASL credentials"])
        {:noreply, state}
    end
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

  defp handle_message(%Message{command: "NICK", params: [nick]}, state) do
    cond do
      state.registered? ->
        send_message(state, "462", [state.nick || "*", "You may not reregister"])
        {:noreply, state}

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

  defp handle_message(
         %Message{command: "USER", params: [username, _mode, _unused, realname]},
         state
       ) do
    state = %{state | username: username, realname: realname}
    Ircxd.Server.identity(state.server, self(), username, realname)
    maybe_register(state)
  end

  defp handle_message(%Message{command: "PING", params: params}, state) do
    send_message(state, "PONG", params)
    {:noreply, state}
  end

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
              "WHOIS"
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

  defp send_message(state, command, params) do
    message = outbound_message(state, %Message{command: command, params: params})
    metadata = %{server: state.server_name, connection: self(), nick: state.nick}
    Ircxd.Server.publish(state.server, message, metadata)
    :gen_tcp.send(state.socket, Message.serialize(message))
  end

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
         MapSet.member?(state.active_capabilities, "server-time") do
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

  defp format_account(account) when is_binary(account), do: account
  defp format_account(account), do: to_string(account)
end
