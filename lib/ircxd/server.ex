defmodule Ircxd.Server do
  @moduledoc """
  Embeddable IRC server.

  Add `{Ircxd.Server, id: :public_irc, port: 6667}` to an application's
  supervision tree. Each server owns its listener and connections, so multiple
  instances can run in the same VM when they have distinct child IDs.
  """

  use GenServer

  alias Ircxd.Casemapping
  alias Ircxd.ISupport
  alias Ircxd.Server.Connection
  alias Ircxd.Server.SubscriberWorker

  @default_server_name "ircxd.local"

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def port(server), do: GenServer.call(server, :port)

  def publish(server, message, metadata),
    do: GenServer.cast(server, {:publish, message, metadata})

  def authenticate(server, username, password, metadata),
    do: GenServer.call(server, {:authenticate, username, password, metadata})

  def command(server, connection, message) do
    GenServer.call(server, {:client_command, connection, message})
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :server_stopped}
  end

  def capabilities(server, connection, capabilities),
    do: GenServer.cast(server, {:client_capabilities, connection, capabilities})

  def identity(server, connection, username, realname),
    do: GenServer.cast(server, {:client_identity, connection, username, realname})

  def register(server, connection, nick),
    do: GenServer.call(server, {:register, connection, nick})

  def change_nick(server, connection, nick),
    do: GenServer.call(server, {:change_nick, connection, nick})

  def verify_password(server, password),
    do: GenServer.call(server, {:verify_password, password})

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 6667)
    server_name = Keyword.get(opts, :server_name, @default_server_name)
    password = Keyword.get(opts, :password)
    tls? = Keyword.get(opts, :tls, false)
    tls_options = Keyword.get(opts, :tls_options, [])
    external_auth? = Keyword.get(opts, :external_auth, false)
    motd = normalize_motd(Keyword.get(opts, :motd, []))
    info = normalize_info(Keyword.get(opts, :info))
    help = normalize_help(Keyword.get(opts, :help))
    isupport = normalize_isupport(Keyword.get(opts, :isupport))
    casemapping = casemapping_from_isupport(isupport)
    admin = normalize_admin(Keyword.get(opts, :admin))

    with :ok <- validate_external_auth(external_auth?, tls?, tls_options),
         {:ok, authenticator} <- init_authenticator(Keyword.get(opts, :authenticator)),
         {:ok, {transport, listener}} <- listen(port, tls?, tls_options),
         {:ok, {_address, actual_port}} <- socket_name(transport, listener) do
      case init_subscriber(Keyword.get(opts, :subscriber)) do
        {:ok, subscriber} ->
          {:ok, handshake_supervisor} =
            Task.Supervisor.start_link(
              max_children: normalize_max_handshakes(Keyword.get(opts, :max_handshakes, 128))
            )

          owner = self()

          handshake_timeout =
            normalize_handshake_timeout(Keyword.get(opts, :handshake_timeout, 5_000))

          {:ok, acceptor} =
            Task.start(fn ->
              accept_loop(
                transport,
                listener,
                owner,
                handshake_supervisor,
                handshake_timeout
              )
            end)

          {:ok,
           %{
             listener: listener,
             transport: transport,
             acceptor: acceptor,
             handshake_supervisor: handshake_supervisor,
             port: actual_port,
             server_name: server_name,
             password: password,
             motd: motd,
             info: info,
             help: help,
             started_at: System.monotonic_time(:second),
             isupport: isupport,
             casemapping: casemapping,
             admin: admin,
             registration_timeout: Keyword.get(opts, :registration_timeout, 60_000),
             max_connections:
               normalize_max_connections(Keyword.get(opts, :max_connections, 1_024)),
             command_rate_limit:
               normalize_command_rate_limit(Keyword.get(opts, :command_rate_limit, 100)),
             connections: %{},
             nick_index: %{},
             channels: %{},
             channel_index: %{},
             whowas: %{},
             channel_operators: %{},
             channel_voices: %{},
             channel_modes: %{},
             invites: %{},
             topics: %{},
             channel_keys: %{},
             channel_limits: %{},
             channel_bans: %{},
             batches: %{},
             history: [],
             history_limit: normalize_history_limit(Keyword.get(opts, :history_limit, 1_000)),
             monitors: %{},
             connection_capabilities: %{},
             message_id: 0,
             capabilities: capabilities(not is_nil(authenticator)),
             external_auth?: external_auth?,
             subscriber: subscriber,
             authenticator: authenticator
           }}

        {:error, reason} ->
          close_socket(transport, listener)
          {:stop, reason}
      end
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:register, connection, nick}, _from, state) do
    nick_key = fold_name(state, nick)

    nick_in_use? =
      case Map.get(state.nick_index, nick_key) do
        nil -> false
        ^connection -> false
        _other -> true
      end

    if nick_in_use? do
      {:reply, {:error, :nick_in_use}, state}
    else
      connections =
        Map.update!(state.connections, connection, fn client ->
          %{client | nick: nick, registered?: true}
        end)

      state = %{
        state
        | connections: connections,
          nick_index: Map.put(state.nick_index, nick_key, connection)
      }

      state = notify_monitors(state, nick, :online)

      state =
        case state.connections[connection].account do
          nil -> state
          account -> notify_account(state, connection, account)
        end

      {:reply, :ok, state}
    end
  end

  def handle_call({:change_nick, connection, nick}, _from, state) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{channels: channels} = client} ->
        nick_key = fold_name(state, nick)

        nick_in_use? =
          case Map.get(state.nick_index, nick_key) do
            nil -> false
            ^connection -> false
            _other -> true
          end

        if nick_in_use? do
          {:reply, {:error, :nick_in_use}, state}
        else
          state = record_whowas(state, client.nick, client)

          recipients =
            Enum.reduce(channels, MapSet.new([connection]), fn channel, recipients ->
              MapSet.union(recipients, Map.get(state.channels, channel, MapSet.new()))
            end)

          connections = Map.put(state.connections, connection, %{client | nick: nick})

          nick_index =
            state.nick_index
            |> Map.delete(fold_name(state, client.nick))
            |> Map.put(nick_key, connection)

          message = %Ircxd.Message{
            source: source_for(client, state.server_name),
            command: "NICK",
            params: [nick]
          }

          state = %{state | connections: connections, nick_index: nick_index}
          {:reply, :ok, broadcast(state, recipients, message, connection)}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:verify_password, password}, _from, state) do
    reply =
      if is_nil(state.password) or to_string(state.password) == to_string(password) do
        :ok
      else
        {:error, :invalid_password}
      end

    {:reply, reply, state}
  end

  def handle_call({:authenticate, username, password, metadata}, _from, state) do
    case state.authenticator do
      nil ->
        {:reply, {:error, :authentication_not_configured}, state}

      authenticator ->
        case invoke_authenticator(authenticator, username, password, metadata) do
          {:ok, account, authenticator_state} ->
            state = %{state | authenticator: %{authenticator | state: authenticator_state}}

            registered? =
              case Map.fetch(state.connections, metadata.connection) do
                {:ok, client} -> client.registered?
                :error -> false
              end

            connections =
              case Map.fetch(state.connections, metadata.connection) do
                {:ok, client} ->
                  Map.put(state.connections, metadata.connection, %{client | account: account})

                :error ->
                  state.connections
              end

            state = %{state | connections: connections}

            state =
              if registered?,
                do: notify_account(state, metadata.connection, account),
                else: state

            {:reply, {:ok, account}, state}

          {:error, reason, authenticator_state} ->
            state = %{state | authenticator: %{authenticator | state: authenticator_state}}
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:client_command, connection, message}, _from, state) do
    {:reply, :ok, handle_client_command(state, connection, message)}
  end

  @impl true
  def handle_cast({:publish, message, metadata}, state) do
    {:noreply, dispatch_to_subscriber(state, message, metadata)}
  end

  def handle_cast({:client_identity, connection, username, realname}, state) do
    case Map.fetch(state.connections, connection) do
      {:ok, client} ->
        connections =
          Map.put(state.connections, connection, %{
            client
            | username: username,
              realname: realname
          })

        {:noreply, %{state | connections: connections}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:client_capabilities, connection, capabilities}, state) do
    {:noreply,
     %{
       state
       | connection_capabilities: Map.put(state.connection_capabilities, connection, capabilities)
     }}
  end

  @impl true
  def handle_info(
        {:accepted, transport, socket},
        %{connections: connections, max_connections: max_connections} = state
      )
      when map_size(connections) >= max_connections do
    close_socket(transport, socket)
    {:noreply, state}
  end

  def handle_info({:accepted, transport, socket}, state) do
    case Connection.start(
           socket: socket,
           transport: transport,
           server: self(),
           server_name: state.server_name,
           isupport: state.isupport,
           password: state.password,
           registration_timeout: state.registration_timeout,
           command_rate_limit: state.command_rate_limit,
           auth_required?: not is_nil(state.authenticator),
           external_auth?: state.external_auth?,
           capabilities: state.capabilities
         ) do
      {:ok, connection} ->
        case controlling_process(transport, socket, connection) do
          :ok ->
            send(connection, :activate)
            ref = Process.monitor(connection)

            connection_state = %{
              socket: socket,
              ref: ref,
              nick: nil,
              username: nil,
              realname: nil,
              account: nil,
              away: nil,
              registered?: false,
              channels: MapSet.new()
            }

            {:noreply,
             %{
               state
               | connections: Map.put(state.connections, connection, connection_state),
                 connection_capabilities:
                   Map.put(state.connection_capabilities, connection, MapSet.new())
             }}

          {:error, reason} ->
            Process.exit(connection, :shutdown)
            close_socket(transport, socket)
            {:stop, reason, state}
        end

      {:error, reason} ->
        close_socket(transport, socket)
        {:stop, reason, state}
    end
  end

  def handle_info({:server_client_registered, connection, nick}, state) do
    {:noreply, update_in(state.connections[connection], &Map.put(&1, :nick, nick))}
  end

  def handle_info({:DOWN, _ref, :process, connection, _reason}, state) do
    state = broadcast_disconnect(state, connection)
    {:noreply, remove_connection(state, connection)}
  end

  def handle_info({:tls_handshake_error, _reason}, state), do: {:noreply, state}
  def handle_info({:accept_error, reason}, state), do: {:stop, {:accept_error, reason}, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.acceptor), do: Process.exit(state.acceptor, :shutdown)
    close_socket(state.transport, state.listener)
    Enum.each(Map.keys(state.connections), &Process.exit(&1, :shutdown))

    if state.subscriber, do: GenServer.stop(state.subscriber.pid, :shutdown)
    if Process.alive?(state.handshake_supervisor), do: Supervisor.stop(state.handshake_supervisor)
  end

  defp listen(port, false, _tls_options) do
    case :gen_tcp.listen(
           port,
           [
             :binary,
             packet: :line,
             packet_size: Ircxd.Message.max_received_wire_bytes(),
             active: false,
             reuseaddr: true
           ]
         ) do
      {:ok, listener} -> {:ok, {:gen_tcp, listener}}
      error -> error
    end
  end

  defp listen(port, true, tls_options) do
    :ssl.start()

    options =
      [
        packet: :line,
        packet_size: Ircxd.Message.max_received_wire_bytes(),
        active: false,
        reuseaddr: true
      ]
      |> Keyword.merge(tls_options)
      |> then(&[:binary | &1])

    case :ssl.listen(port, options) do
      {:ok, listener} -> {:ok, {:ssl, listener}}
      error -> error
    end
  end

  defp socket_name(:gen_tcp, listener), do: :inet.sockname(listener)
  defp socket_name(:ssl, listener), do: :ssl.sockname(listener)

  defp controlling_process(:gen_tcp, socket, process),
    do: :gen_tcp.controlling_process(socket, process)

  defp controlling_process(:ssl, socket, process), do: :ssl.controlling_process(socket, process)

  defp close_socket(:gen_tcp, socket), do: :gen_tcp.close(socket)
  defp close_socket(:ssl, socket), do: :ssl.close(socket)

  defp init_subscriber(nil), do: {:ok, nil}

  defp init_subscriber({module, arg}) do
    case SubscriberWorker.start(module, arg) do
      {:ok, pid} -> {:ok, %{pid: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp init_authenticator(nil), do: {:ok, nil}

  defp init_authenticator({module, arg}) do
    result =
      try do
        module.init(arg)
      rescue
        _error -> {:error, :initialization_failed}
      catch
        _kind, _reason -> {:error, :initialization_failed}
      end

    case result do
      {:ok, authenticator_state} -> {:ok, %{module: module, state: authenticator_state}}
      {:error, reason} -> {:error, {:authenticator_init_failed, reason}}
      _other -> {:error, {:authenticator_init_failed, :invalid_return}}
    end
  end

  defp invoke_authenticator(authenticator, username, password, metadata) do
    result =
      try do
        authenticator.module.authenticate(
          username,
          password,
          metadata,
          authenticator.state
        )
      rescue
        _error -> {:error, :authentication_failed, authenticator.state}
      catch
        _kind, _reason -> {:error, :authentication_failed, authenticator.state}
      end

    case result do
      {:ok, _account, _authenticator_state} -> result
      {:error, _reason, _authenticator_state} -> result
      _other -> {:error, :authentication_failed, authenticator.state}
    end
  end

  defp capabilities(auth_required?) do
    if auth_required?,
      do: [
        "message-tags",
        "server-time",
        "extended-join",
        "away-notify",
        "account-notify",
        "account-tag",
        "multi-prefix",
        "userhost-in-names",
        "no-implicit-names",
        "setname",
        "echo-message",
        "invite-notify",
        "labeled-response",
        "standard-replies",
        "batch",
        "draft/chathistory",
        "draft/multiline",
        "draft/message-redaction",
        "sasl"
      ],
      else: [
        "message-tags",
        "server-time",
        "extended-join",
        "away-notify",
        "account-notify",
        "account-tag",
        "multi-prefix",
        "userhost-in-names",
        "no-implicit-names",
        "setname",
        "echo-message",
        "invite-notify",
        "labeled-response",
        "standard-replies",
        "batch",
        "draft/chathistory",
        "draft/multiline",
        "draft/message-redaction"
      ]
  end

  defp normalize_motd(motd) when is_binary(motd), do: String.split(motd, "\n")
  defp normalize_motd(motd) when is_list(motd), do: Enum.map(motd, &to_string/1)
  defp normalize_motd(_motd), do: []

  defp normalize_history_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, 10_000)

  defp normalize_history_limit(_limit), do: 1_000

  defp normalize_handshake_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_handshake_timeout(_timeout), do: 5_000

  defp normalize_max_handshakes(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_max_handshakes(_limit), do: 128

  defp normalize_max_connections(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_max_connections(_limit), do: 1_024

  defp normalize_command_rate_limit(:infinity), do: :infinity

  defp normalize_command_rate_limit(limit) when is_integer(limit) and limit > 0,
    do: limit

  defp normalize_command_rate_limit(_limit), do: 100

  defp validate_external_auth(false, _tls?, _tls_options), do: :ok

  defp validate_external_auth(true, true, tls_options) do
    trust_configured? = Enum.any?([:cacerts, :cacertfile], &Keyword.has_key?(tls_options, &1))

    if Keyword.get(tls_options, :verify) == :verify_peer and trust_configured? do
      :ok
    else
      {:error, :external_auth_requires_verified_client_certificates}
    end
  end

  defp validate_external_auth(true, false, _tls_options),
    do: {:error, :external_auth_requires_tls}

  defp parse_history_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} when limit > 0 -> min(limit, 100)
      _ -> 50
    end
  end

  defp parse_history_limit(_limit), do: 50

  defp normalize_info(nil), do: ["Ircxd.Server", "Embeddable IRC server for Elixir applications"]
  defp normalize_info(info) when is_binary(info), do: [info]
  defp normalize_info(info) when is_list(info), do: Enum.map(info, &to_string/1)
  defp normalize_info(_info), do: normalize_info(nil)

  defp normalize_help(nil), do: %{}

  defp normalize_help(help) when is_map(help) do
    Enum.into(help, %{}, fn {subject, lines} ->
      {String.upcase(to_string(subject)), lines |> List.wrap() |> Enum.map(&to_string/1)}
    end)
  end

  defp normalize_help(_help), do: normalize_help(nil)

  defp format_uptime(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    seconds = rem(seconds, 60)
    "Server up #{days} days, #{hours} hours, #{minutes} minutes, #{seconds} seconds"
  end

  defp normalize_isupport(nil),
    do: [
      "CHANTYPES=#&",
      "NICKLEN=30",
      "CASEMAPPING=ascii",
      "PREFIX=(ov)@+",
      "CHANMODES=b,k,l,imnpst",
      "CHATHISTORY=100",
      "MSGREFTYPES=msgid,timestamp"
    ]

  defp normalize_isupport(tokens) when is_binary(tokens),
    do: tokens |> String.split(" ", trim: true) |> normalize_casemapping_token()

  defp normalize_isupport(tokens) when is_list(tokens),
    do: tokens |> Enum.map(&to_string/1) |> normalize_casemapping_token()

  defp normalize_isupport(_tokens), do: normalize_isupport(nil)

  defp normalize_casemapping_token(tokens) do
    Enum.map(tokens, fn
      "CASEMAPPING=" <> mapping
      when mapping in ["ascii", "rfc1459", "strict-rfc1459"] ->
        "CASEMAPPING=" <> mapping

      "CASEMAPPING" <> _invalid ->
        "CASEMAPPING=rfc1459"

      token ->
        token
    end)
  end

  defp casemapping_from_isupport(tokens) do
    tokens
    |> Enum.map(&ISupport.parse_token/1)
    |> Map.new()
    |> ISupport.casemap()
  end

  defp normalize_admin(nil), do: %{location: [], email: nil}

  defp normalize_admin(admin) when is_map(admin) do
    %{location: List.wrap(Map.get(admin, :location, [])), email: Map.get(admin, :email)}
  end

  defp normalize_admin(_admin), do: normalize_admin(nil)

  defp dispatch_to_subscriber(%{subscriber: nil} = state, _message, _metadata), do: state

  defp dispatch_to_subscriber(%{subscriber: subscriber} = state, message, metadata) do
    GenServer.cast(subscriber.pid, {:publish, message, metadata})
    state
  end

  defp handle_client_command(state, connection, message) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{registered?: true}} ->
        handle_registered_command(
          state,
          connection,
          resolve_command_targets(state, message)
        )

      {:ok, %{nick: nick}} ->
        error_reply(state, connection, "451", [nick || "*", "You have not registered"])

      :error ->
        state
    end
  end

  defp resolve_command_targets(state, %{command: command, params: [targets | rest]} = message)
       when command in ["JOIN", "PART", "PRIVMSG", "NOTICE"] do
    %{message | params: [resolve_csv_targets(state, targets) | rest]}
  end

  defp resolve_command_targets(state, %{command: "TAGMSG", params: [target | rest]} = message),
    do: %{message | params: [resolve_named_target(state, target) | rest]}

  defp resolve_command_targets(state, %{command: command, params: [target | rest]} = message)
       when command in ["NAMES", "TOPIC", "WHO"] do
    %{message | params: [resolve_named_target(state, target) | rest]}
  end

  defp resolve_command_targets(
         state,
         %{command: "MODE", params: [target, modes | mode_params]} = message
       ) do
    target = resolve_named_target(state, target)

    mode_params =
      if valid_channel?(target) and modes in ["+o", "-o", "+v", "-v"] do
        Enum.map(mode_params, &resolve_existing_nick(state, &1))
      else
        mode_params
      end

    %{message | params: [target, modes | mode_params]}
  end

  defp resolve_command_targets(state, %{command: "MODE", params: [target]} = message),
    do: %{message | params: [resolve_named_target(state, target)]}

  defp resolve_command_targets(
         state,
         %{command: "INVITE", params: [nick, channel | rest]} = message
       ) do
    %{
      message
      | params: [
          resolve_existing_nick(state, nick),
          resolve_existing_channel(state, channel) | rest
        ]
    }
  end

  defp resolve_command_targets(
         state,
         %{command: "KICK", params: [channel, nick | rest]} = message
       ) do
    %{
      message
      | params: [
          resolve_existing_channel(state, channel),
          resolve_existing_nick(state, nick) | rest
        ]
    }
  end

  defp resolve_command_targets(state, %{command: command, params: params} = message)
       when command in ["ISON", "USERHOST"] do
    %{message | params: Enum.map(params, &resolve_existing_nick(state, &1))}
  end

  defp resolve_command_targets(state, %{command: "WHOIS", params: [target | rest]} = message),
    do: %{message | params: [resolve_existing_nick(state, target) | rest]}

  defp resolve_command_targets(
         _state,
         %{command: "CHATHISTORY", params: ["TARGETS" | _rest]} = message
       ),
       do: message

  defp resolve_command_targets(
         state,
         %{command: "CHATHISTORY", params: [query, target | rest]} = message
       ),
       do: %{message | params: [query, resolve_existing_channel(state, target) | rest]}

  defp resolve_command_targets(state, %{command: "REDACT", params: [target | rest]} = message),
    do: %{message | params: [resolve_existing_channel(state, target) | rest]}

  defp resolve_command_targets(_state, message), do: message

  defp resolve_csv_targets(state, targets) do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&resolve_named_target(state, &1))
    |> Enum.join(",")
  end

  defp resolve_named_target(state, target) do
    if valid_channel?(target),
      do: resolve_existing_channel(state, target),
      else: resolve_existing_nick(state, target)
  end

  defp resolve_existing_channel(state, channel) do
    Map.get(state.channel_index, fold_name(state, channel), channel)
  end

  defp resolve_existing_nick(state, nick) do
    case Map.get(state.nick_index, fold_name(state, nick)) do
      nil -> nick
      connection -> state.connections[connection].nick
    end
  end

  defp find_connection_by_nick(state, nick) do
    case Map.get(state.nick_index, fold_name(state, nick)) do
      nil -> nil
      connection -> {connection, state.connections[connection]}
    end
  end

  defp nick_online?(state, nick), do: not is_nil(find_connection_by_nick(state, nick))

  defp fold_name(state, value) when is_binary(value),
    do: Casemapping.normalize(value, state.casemapping)

  defp handle_registered_command(state, connection, %{
         command: "JOIN",
         params: []
       }) do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "JOIN",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "JOIN",
         params: ["0"]
       }) do
    state.connections[connection].channels
    |> MapSet.to_list()
    |> Enum.reduce(state, fn channel, state -> part_channel(state, connection, channel, []) end)
  end

  defp handle_registered_command(state, connection, %{
         command: "JOIN",
         params: [channel, key]
       }) do
    channel
    |> String.split(",", trim: true)
    |> Enum.reduce(state, fn channel, state -> join_channel(state, connection, channel, key) end)
  end

  defp handle_registered_command(state, connection, %{
         command: "JOIN",
         params: [channel]
       }) do
    channel
    |> String.split(",", trim: true)
    |> Enum.reduce(state, fn channel, state -> join_channel(state, connection, channel, nil) end)
  end

  defp handle_registered_command(state, connection, %{
         command: "NAMES",
         params: [channel]
       }) do
    names_channel(state, connection, channel)
  end

  defp handle_registered_command(state, connection, %{command: "NAMES", params: []}) do
    state.channels
    |> Enum.filter(&channel_visible_to_names?(state, connection, &1))
    |> Enum.reduce(state, fn {channel, _members}, state ->
      names_channel(state, connection, channel)
    end)
  end

  defp handle_registered_command(state, connection, %{
         command: "ISON",
         params: targets
       }) do
    nick = state.connections[connection].nick

    online_nicks =
      targets
      |> Enum.flat_map(fn target ->
        if nick_online?(state, target),
          do: [target],
          else: []
      end)

    message = %Ircxd.Message{
      source: state.server_name,
      command: "303",
      params: [nick, Enum.join(online_nicks, " ")]
    }

    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp handle_registered_command(state, connection, %{
         command: "USERHOST",
         params: targets
       }) do
    nick = state.connections[connection].nick

    replies =
      targets
      |> Enum.flat_map(fn target ->
        case find_connection_by_nick(state, target) do
          {_pid, client} ->
            away = if is_nil(client.away), do: "+", else: "-"
            username = client.username || client.nick
            ["#{client.nick}=#{away}#{username}@#{state.server_name}"]

          nil ->
            []
        end
      end)
      |> Enum.join(" ")

    message = %Ircxd.Message{
      source: state.server_name,
      command: "302",
      params: [nick, replies]
    }

    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp handle_registered_command(state, connection, %{
         command: "LIST",
         params: params
       }) do
    nick = state.connections[connection].nick
    channels = channels_for_list(state, connection, params)

    start_message = %Ircxd.Message{
      source: state.server_name,
      command: "321",
      params: [nick, "Channel", "Users Name"]
    }

    state = broadcast(state, MapSet.new([connection]), start_message, connection)

    state =
      Enum.reduce(channels, state, fn {channel, members}, state ->
        entry = %Ircxd.Message{
          source: state.server_name,
          command: "322",
          params: [
            nick,
            channel,
            Integer.to_string(MapSet.size(members)),
            Map.get(state.topics, channel, "")
          ]
        }

        broadcast(state, MapSet.new([connection]), entry, connection)
      end)

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "323",
      params: [nick, "End of /LIST"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{command: "MOTD"}) do
    nick = state.connections[connection].nick

    start_message = %Ircxd.Message{
      source: state.server_name,
      command: "375",
      params: [nick, "- #{state.server_name} Message of the day -"]
    }

    state = broadcast(state, MapSet.new([connection]), start_message, connection)

    state =
      Enum.reduce(state.motd, state, fn line, state ->
        message = %Ircxd.Message{source: state.server_name, command: "372", params: [nick, line]}
        broadcast(state, MapSet.new([connection]), message, connection)
      end)

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "376",
      params: [nick, "End of /MOTD command"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{command: "LUSERS"}) do
    nick = state.connections[connection].nick
    users = Enum.count(state.connections, fn {_pid, client} -> client.registered? end)
    channels = map_size(state.channels)

    replies = [
      {"251", [nick, "There are #{users} users and 0 services on 1 servers"]},
      {"252", [nick, "0", "operator(s) online"]},
      {"253", [nick, "0", "unknown connection(s)"]},
      {"254", [nick, Integer.to_string(channels), "channels formed"]},
      {"255", [nick, "I have #{users} clients and 1 servers"]}
    ]

    Enum.reduce(replies, state, fn {command, params}, state ->
      message = %Ircxd.Message{source: state.server_name, command: command, params: params}
      broadcast(state, MapSet.new([connection]), message, connection)
    end)
  end

  defp handle_registered_command(state, connection, %{command: "VERSION"}) do
    nick = state.connections[connection].nick

    message = %Ircxd.Message{
      source: state.server_name,
      command: "351",
      params: [nick, "Ircxd.Server", state.server_name, "Ircxd server"]
    }

    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp handle_registered_command(state, connection, %{command: "TIME"}) do
    nick = state.connections[connection].nick

    message = %Ircxd.Message{
      source: state.server_name,
      command: "391",
      params: [nick, state.server_name, DateTime.utc_now() |> DateTime.to_iso8601()]
    }

    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp handle_registered_command(state, connection, %{command: "ADMIN"}) do
    nick = state.connections[connection].nick

    start_message = %Ircxd.Message{
      source: state.server_name,
      command: "256",
      params: [nick, state.server_name, "Administrative info"]
    }

    state = broadcast(state, MapSet.new([connection]), start_message, connection)

    state =
      state.admin.location
      |> Enum.take(2)
      |> Enum.with_index(257)
      |> Enum.reduce(state, fn {line, command}, state ->
        message = %Ircxd.Message{
          source: state.server_name,
          command: Integer.to_string(command),
          params: [nick, line]
        }

        broadcast(state, MapSet.new([connection]), message, connection)
      end)

    case state.admin.email do
      email when is_binary(email) ->
        message = %Ircxd.Message{source: state.server_name, command: "259", params: [nick, email]}
        broadcast(state, MapSet.new([connection]), message, connection)

      _ ->
        state
    end
  end

  defp handle_registered_command(state, connection, %{command: "INFO"}) do
    nick = state.connections[connection].nick

    state =
      Enum.reduce(state.info, state, fn line, state ->
        message = %Ircxd.Message{source: state.server_name, command: "371", params: [nick, line]}
        broadcast(state, MapSet.new([connection]), message, connection)
      end)

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "374",
      params: [nick, "End of /INFO list"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{
         command: "HELP",
         params: params
       }) do
    nick = state.connections[connection].nick
    subject = params |> List.first() |> to_string() |> String.upcase()

    case Map.fetch(state.help, subject) do
      {:ok, lines} ->
        start_message = %Ircxd.Message{
          source: state.server_name,
          command: "704",
          params: [nick, subject, "Help for #{subject}"]
        }

        state = broadcast(state, MapSet.new([connection]), start_message, connection)

        state =
          Enum.reduce(lines, state, fn line, state ->
            message = %Ircxd.Message{
              source: state.server_name,
              command: "705",
              params: [nick, subject, line]
            }

            broadcast(state, MapSet.new([connection]), message, connection)
          end)

        end_message = %Ircxd.Message{
          source: state.server_name,
          command: "706",
          params: [nick, subject, "End of HELP"]
        }

        broadcast(state, MapSet.new([connection]), end_message, connection)

      :error ->
        error_reply(state, connection, "524", [nick, subject, "No help available"])
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "LINKS",
         params: params
       }) do
    nick = state.connections[connection].nick

    {remote, mask} =
      case params do
        [] -> {nil, "*"}
        [remote] -> {remote, "*"}
        [remote, mask | _rest] -> {remote, mask}
      end

    state =
      if remote in [nil, "*", state.server_name] and
           casemapped_wildcard_match?(state, mask, state.server_name) do
        message = %Ircxd.Message{
          source: state.server_name,
          command: "364",
          params: [nick, mask, state.server_name, "0", "Ircxd server"]
        }

        broadcast(state, MapSet.new([connection]), message, connection)
      else
        state
      end

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "365",
      params: [nick, mask, "End of LINKS list"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{
         command: "STATS",
         params: ["u" | _rest]
       }) do
    nick = state.connections[connection].nick
    elapsed = max(System.monotonic_time(:second) - state.started_at, 0)

    uptime = %Ircxd.Message{
      source: state.server_name,
      command: "242",
      params: [nick, format_uptime(elapsed)]
    }

    state = broadcast(state, MapSet.new([connection]), uptime, connection)

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "219",
      params: [nick, "u", "End of STATS report"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{command: "STATS", params: params}) do
    nick = state.connections[connection].nick
    query = List.first(params) || "*"

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "219",
      params: [nick, query, "End of STATS report"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{
         command: "WHO",
         params: []
       }) do
    handle_registered_command(state, connection, %{command: "WHO", params: ["*"]})
  end

  defp handle_registered_command(state, connection, %{
         command: "WHO",
         params: [mask | _rest]
       }) do
    requester = state.connections[connection].nick

    {members, reply_channel} =
      case Map.fetch(state.channels, mask) do
        {:ok, members} ->
          secret? = MapSet.member?(Map.get(state.channel_modes, mask, MapSet.new()), "s")

          members =
            if secret? and not MapSet.member?(members, connection),
              do: MapSet.new(),
              else: members

          {members, mask}

        :error ->
          members =
            if mask == "*" do
              state.connections
              |> Enum.filter(fn {_member, client} -> client.registered? end)
              |> Enum.map(&elem(&1, 0))
              |> MapSet.new()
            else
              case find_connection_by_nick(state, mask) do
                {member, _client} -> MapSet.new([member])
                nil -> MapSet.new()
              end
            end

          {members, "*"}
      end

    state =
      Enum.reduce(members, state, fn member, state ->
        client = state.connections[member]
        username = client.username || client.nick
        realname = client.realname || client.nick

        message = %Ircxd.Message{
          source: state.server_name,
          command: "352",
          params: [
            requester,
            reply_channel,
            username,
            "user",
            state.server_name,
            client.nick,
            "H",
            "0 #{realname}"
          ]
        }

        broadcast(state, MapSet.new([connection]), message, connection)
      end)

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "315",
      params: [requester, mask, "End of /WHO list"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp handle_registered_command(state, connection, %{command: "WHOIS", params: []}) do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "WHOIS",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "WHOIS",
         params: [target | _rest],
         tags: tags
       }) do
    requester = state.connections[connection].nick
    response_tags = Map.take(tags, ["label"])

    case find_connection_by_nick(state, target) do
      nil ->
        error_reply(state, connection, "401", [requester, target, "No such nick/channel"])

      {_pid, client} ->
        username = client.username || client.nick
        realname = client.realname || client.nick

        user_message = %Ircxd.Message{
          tags: response_tags,
          source: state.server_name,
          command: "311",
          params: [requester, client.nick, username, "user", "*", realname]
        }

        state = broadcast(state, MapSet.new([connection]), user_message, connection)

        state =
          case client.away do
            nil ->
              state

            away ->
              away_message = %Ircxd.Message{
                tags: response_tags,
                source: state.server_name,
                command: "301",
                params: [requester, client.nick, away]
              }

              broadcast(state, MapSet.new([connection]), away_message, connection)
          end

        state =
          case client.account do
            nil ->
              state

            account ->
              account_message = %Ircxd.Message{
                tags: response_tags,
                source: state.server_name,
                command: "330",
                params: [requester, client.nick, format_account(account), "is logged in as"]
              }

              broadcast(state, MapSet.new([connection]), account_message, connection)
          end

        server_message = %Ircxd.Message{
          tags: response_tags,
          source: state.server_name,
          command: "312",
          params: [requester, client.nick, state.server_name, "Ircxd server"]
        }

        state = broadcast(state, MapSet.new([connection]), server_message, connection)

        end_message = %Ircxd.Message{
          tags: response_tags,
          source: state.server_name,
          command: "318",
          params: [requester, client.nick, "End of /WHOIS list"]
        }

        broadcast(state, MapSet.new([connection]), end_message, connection)
    end
  end

  defp handle_registered_command(state, connection, %{command: "WHOWAS", params: []}) do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "WHOWAS",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "WHOWAS",
         params: [target | rest]
       }) do
    requester = state.connections[connection].nick

    entries =
      state.whowas
      |> Map.get(fold_name(state, target), [])
      |> Enum.take(whowas_count(rest))

    if entries == [] do
      error_reply(state, connection, "406", [requester, target, "There was no such nickname"])
    else
      state =
        Enum.reduce(entries, state, fn entry, state ->
          message = %Ircxd.Message{
            source: state.server_name,
            command: "314",
            params: [requester, entry.nick, entry.username, entry.host, "*", entry.realname]
          }

          broadcast(state, MapSet.new([connection]), message, connection)
        end)

      end_message = %Ircxd.Message{
        source: state.server_name,
        command: "369",
        params: [requester, target, "End of WHOWAS"]
      }

      broadcast(state, MapSet.new([connection]), end_message, connection)
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "PART",
         params: []
       }) do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "PART",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "PART",
         params: [channel | rest]
       }) do
    channel
    |> String.split(",", trim: true)
    |> Enum.reduce(state, fn channel, state -> part_channel(state, connection, channel, rest) end)
  end

  defp handle_registered_command(state, connection, %{
         command: "KICK",
         params: params
       })
       when length(params) < 2 do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "KICK",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "KICK",
         params: [channel, target | rest]
       }) do
    kick_member(state, connection, channel, target, rest)
  end

  defp handle_registered_command(state, connection, %{
         command: "INVITE",
         params: params
       })
       when length(params) < 2 do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "INVITE",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "INVITE",
         params: [target, channel]
       }) do
    invite_member(state, connection, target, channel)
  end

  defp handle_registered_command(state, connection, %{
         command: "QUIT",
         params: params
       }) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick, channels: channels} = client} when is_binary(nick) ->
        recipients =
          Enum.reduce(channels, MapSet.new(), fn channel, recipients ->
            MapSet.union(recipients, Map.get(state.channels, channel, MapSet.new()))
          end)

        message = %Ircxd.Message{
          source: source_for(client, state.server_name),
          command: "QUIT",
          params: params
        }

        state = broadcast(state, recipients, message, connection)
        remove_connection(state, connection)

      _ ->
        state
    end
  end

  defp handle_registered_command(state, connection, %{command: "TOPIC", params: []}) do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "TOPIC",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "TOPIC",
         params: [channel, topic]
       }) do
    members = Map.get(state.channels, channel, MapSet.new())

    if MapSet.member?(members, connection) do
      topic_locked? = MapSet.member?(Map.get(state.channel_modes, channel, MapSet.new()), "t")

      if topic_locked? and not channel_operator?(state, channel, connection) do
        error_reply(state, connection, "482", [
          state.connections[connection].nick,
          "You're not channel operator"
        ])
      else
        client = state.connections[connection]

        message = %Ircxd.Message{
          source: source_for(client, state.server_name),
          command: "TOPIC",
          params: [channel, topic]
        }

        state = broadcast(state, members, message, connection)
        %{state | topics: Map.put(state.topics, channel, topic)}
      end
    else
      error_reply(state, connection, "442", [
        state.connections[connection].nick,
        channel,
        "You're not on that channel"
      ])
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "TOPIC",
         params: [channel]
       }) do
    nick = state.connections[connection].nick

    case Map.get(state.topics, channel) do
      nil ->
        message = %Ircxd.Message{
          source: state.server_name,
          command: "331",
          params: [nick, channel, "No topic is set"]
        }

        broadcast(state, MapSet.new([connection]), message, connection)

      topic ->
        message = %Ircxd.Message{
          source: state.server_name,
          command: "332",
          params: [nick, channel, topic]
        }

        broadcast(state, MapSet.new([connection]), message, connection)
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "AWAY",
         params: params
       }) do
    client = state.connections[connection]
    away = List.first(params)
    channels = client.channels

    recipients =
      Enum.reduce(channels, MapSet.new(), fn channel, recipients ->
        MapSet.union(recipients, Map.get(state.channels, channel, MapSet.new()))
      end)
      |> capability_recipients(state, "away-notify")

    message = %Ircxd.Message{
      source: source_for(client, state.server_name),
      command: "AWAY",
      params: if(is_nil(away), do: [], else: [away])
    }

    state = broadcast(state, recipients, message, connection)
    connections = Map.put(state.connections, connection, %{client | away: away})
    state = %{state | connections: connections}

    {command, text} =
      if is_nil(away),
        do: {"305", "You are no longer marked as being away"},
        else: {"306", "You have been marked as being away"}

    status = %Ircxd.Message{
      source: state.server_name,
      command: command,
      params: [client.nick, text]
    }

    broadcast(state, MapSet.new([connection]), status, connection)
  end

  defp handle_registered_command(state, connection, %{
         command: "SETNAME",
         params: [realname]
       }) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{channels: channels} = client} ->
        recipients =
          Enum.reduce(channels, MapSet.new([connection]), fn channel, recipients ->
            MapSet.union(recipients, Map.get(state.channels, channel, MapSet.new()))
          end)
          |> capability_recipients(state, "setname")

        message = %Ircxd.Message{
          source: source_for(client, state.server_name),
          command: "SETNAME",
          params: [realname]
        }

        connections = Map.put(state.connections, connection, %{client | realname: realname})
        state = %{state | connections: connections}
        broadcast(state, recipients, message, connection)

      :error ->
        state
    end
  end

  defp handle_registered_command(state, connection, %{
         command: command,
         params: [],
         tags: _tags
       })
       when command in ["PRIVMSG", "NOTICE"] do
    if command == "PRIVMSG" do
      error_reply(state, connection, "411", [
        state.connections[connection].nick,
        "No recipient given"
      ])
    else
      state
    end
  end

  defp handle_registered_command(state, connection, %{
         command: command,
         params: [_target],
         tags: _tags
       })
       when command in ["PRIVMSG", "NOTICE"] do
    if command == "PRIVMSG" do
      error_reply(state, connection, "412", [
        state.connections[connection].nick,
        "No text to send"
      ])
    else
      state
    end
  end

  defp handle_registered_command(state, connection, %{
         command: command,
         params: [target, body],
         tags: tags
       })
       when command in ["PRIVMSG", "NOTICE"] do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
        targets = message_targets(target)

        Enum.reduce(targets, state, fn target, state ->
          case message_recipients(state, connection, target) do
            {:ok, recipients} ->
              recipients = echo_recipients(state, connection, recipients)
              source = source_for(client, state.server_name)

              message = %Ircxd.Message{
                tags: tags,
                source: source,
                command: command,
                params: [target, body]
              }

              {state, message} = record_history(state, message)
              state = maybe_start_batch(state, connection, tags, recipients)
              broadcast(state, recipients, message, connection)

            {:error, error_command, params} when command == "PRIVMSG" ->
              error_reply(state, connection, error_command, params)

            {:error, _error_command, _params} ->
              state
          end
        end)

      _ ->
        state
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "TAGMSG",
         params: [target],
         tags: tags
       }) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
        case message_recipients(state, connection, target) do
          {:ok, recipients} ->
            recipients = echo_recipients(state, connection, recipients)

            source = source_for(client, state.server_name)

            message = %Ircxd.Message{
              tags: tags,
              source: source,
              command: "TAGMSG",
              params: [target]
            }

            state = maybe_start_batch(state, connection, tags, recipients)
            broadcast(state, recipients, message, connection)

          {:error, _error_command, _params} ->
            state
        end

      _ ->
        state
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "CHATHISTORY",
         params: ["TARGETS", first_selector, second_selector, limit | _rest]
       }) do
    serve_history_targets(
      state,
      connection,
      first_selector,
      second_selector,
      parse_history_limit(limit)
    )
  end

  defp handle_registered_command(state, connection, %{
         command: "CHATHISTORY",
         params: ["BETWEEN", target, first_selector, second_selector, limit | _rest]
       }) do
    serve_history(
      state,
      connection,
      "BETWEEN",
      target,
      {first_selector, second_selector},
      parse_history_limit(limit)
    )
  end

  defp handle_registered_command(state, connection, %{
         command: "CHATHISTORY",
         params: [query, target, selector, limit | _rest]
       }) do
    serve_history(state, connection, query, target, selector, parse_history_limit(limit))
  end

  defp handle_registered_command(state, connection, %{
         command: "REDACT",
         params: params
       })
       when length(params) < 2 do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "REDACT",
      "Not enough parameters"
    ])
  end

  defp handle_registered_command(state, connection, %{
         command: "REDACT",
         params: [target, msgid | reason]
       }) do
    redact_message(state, connection, target, msgid, List.first(reason))
  end

  defp handle_registered_command(state, connection, %{command: "CHATHISTORY"}) do
    error_reply(state, connection, "421", [
      state.connections[connection].nick,
      "CHATHISTORY",
      "Unsupported CHATHISTORY query"
    ])
  end

  defp handle_registered_command(
         state,
         connection,
         %{
           command: "BATCH",
           params: params
         } = message
       ) do
    case Ircxd.Batch.parse(params) do
      {:ok, %{direction: :start, ref: ref, type: type, params: batch_params}} ->
        source = source_for(state.connections[connection], state.server_name)

        batch = %{
          message: %{message | source: source},
          type: type,
          params: batch_params,
          recipients: MapSet.new()
        }

        %{state | batches: Map.put(state.batches, {connection, ref}, batch)}

      {:ok, %{direction: :end, ref: ref}} ->
        finish_batch(state, connection, ref, message)

      {:error, _reason} ->
        state
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "MODE",
         params: [target]
       }) do
    nick = state.connections[connection].nick

    cond do
      target == nick ->
        message = %Ircxd.Message{source: state.server_name, command: "221", params: [nick, "+"]}
        broadcast(state, MapSet.new([connection]), message, connection)

      valid_channel?(target) and Map.has_key?(state.channels, target) ->
        message = %Ircxd.Message{
          source: state.server_name,
          command: "324",
          params: [nick, target, channel_mode_string(state, target)]
        }

        broadcast(state, MapSet.new([connection]), message, connection)

      valid_channel?(target) ->
        error_reply(state, connection, "403", [nick, target, "No such channel"])

      true ->
        error_reply(state, connection, "401", [nick, target, "No such nick/channel"])
    end
  end

  defp handle_registered_command(state, connection, %{
         command: "MODE",
         params: [channel, modes | mode_params]
       }) do
    set_channel_mode(state, connection, channel, modes, mode_params)
  end

  defp handle_registered_command(state, connection, %{
         command: "MONITOR",
         params: [subcommand | rest]
       }) do
    handle_monitor_command(state, connection, subcommand, rest)
  end

  defp handle_registered_command(state, connection, %{command: command, tags: tags}) do
    state =
      error_reply(state, connection, "421", [
        state.connections[connection].nick,
        command,
        "Unknown command"
      ])

    if capability_enabled?(state, connection, "standard-replies") do
      standard = %Ircxd.Message{
        tags: Map.take(tags, ["label"]),
        source: state.server_name,
        command: "FAIL",
        params: [command, "UNKNOWN_COMMAND", "Unknown command"]
      }

      broadcast(state, MapSet.new([connection]), standard, connection)
    else
      state
    end
  end

  defp handle_monitor_command(state, connection, "+", [targets]) do
    targets =
      targets
      |> String.split(",", trim: true)
      |> Enum.map(&fold_name(state, &1))

    monitored = Map.get(state.monitors, connection, MapSet.new())
    monitored = Enum.reduce(targets, monitored, &MapSet.put(&2, &1))
    state = %{state | monitors: Map.put(state.monitors, connection, monitored)}
    nick = state.connections[connection].nick

    {online, offline} =
      Enum.split_with(targets, &nick_online?(state, &1))

    state =
      if online == [],
        do: state,
        else:
          monitor_reply(state, connection, "730", [nick, monitor_online_targets(state, online)])

    if offline == [],
      do: state,
      else: monitor_reply(state, connection, "731", [nick, Enum.join(offline, ",")])
  end

  defp handle_monitor_command(state, connection, "-", [targets]) do
    targets =
      targets
      |> String.split(",", trim: true)
      |> Enum.map(&fold_name(state, &1))

    monitored = Map.get(state.monitors, connection, MapSet.new())

    monitored = Enum.reduce(targets, monitored, &MapSet.delete(&2, &1))
    %{state | monitors: Map.put(state.monitors, connection, monitored)}
  end

  defp handle_monitor_command(state, connection, "C", _rest),
    do: %{state | monitors: Map.delete(state.monitors, connection)}

  defp handle_monitor_command(state, connection, subcommand, _rest)
       when subcommand in ["L", "S"] do
    nick = state.connections[connection].nick

    targets =
      state.monitors |> Map.get(connection, MapSet.new()) |> MapSet.to_list() |> Enum.sort()

    state = monitor_reply(state, connection, "732", [nick, Enum.join(targets, ",")])
    monitor_reply(state, connection, "733", [nick, "End of MONITOR list"])
  end

  defp handle_monitor_command(state, _connection, _subcommand, _rest), do: state

  defp monitor_online_targets(state, targets) do
    targets
    |> Enum.map(fn target ->
      {_pid, client} = find_connection_by_nick(state, target)

      source_for(client, state.server_name)
    end)
    |> Enum.join(",")
  end

  defp monitor_reply(state, connection, command, params) do
    message = %Ircxd.Message{source: state.server_name, command: command, params: params}
    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp notify_monitors(state, nil, _status), do: state

  defp notify_monitors(state, nick, status) do
    nick_key = fold_name(state, nick)

    Enum.reduce(state.monitors, state, fn {watcher, targets}, state ->
      if MapSet.member?(targets, nick_key) and Map.has_key?(state.connections, watcher) do
        watcher_nick = state.connections[watcher].nick

        case status do
          :online ->
            {_pid, client} = find_connection_by_nick(state, nick)
            target = source_for(client, state.server_name)

            monitor_reply(state, watcher, "730", [watcher_nick, target])

          :offline ->
            monitor_reply(state, watcher, "731", [watcher_nick, nick])
        end
      else
        state
      end
    end)
  end

  defp notify_account(state, connection, account) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{channels: channels} = client} ->
        recipients =
          Enum.reduce(channels, MapSet.new([connection]), fn channel, recipients ->
            MapSet.union(recipients, Map.get(state.channels, channel, MapSet.new()))
          end)
          |> capability_recipients(state, "account-notify")

        message = %Ircxd.Message{
          source: source_for(client, state.server_name),
          command: "ACCOUNT",
          params: [if(is_nil(account), do: "*", else: format_account(account))]
        }

        broadcast(state, recipients, message, connection)

      :error ->
        state
    end
  end

  defp names_channel(state, connection, channel) do
    members = Map.get(state.channels, channel, MapSet.new())
    secret? = MapSet.member?(Map.get(state.channel_modes, channel, MapSet.new()), "s")

    if secret? and not MapSet.member?(members, connection) do
      end_message = %Ircxd.Message{
        source: state.server_name,
        command: "366",
        params: [state.connections[connection].nick, channel, "End of NAMES list"]
      }

      broadcast(state, MapSet.new([connection]), end_message, connection)
    else
      names_channel_visible(state, connection, channel)
    end
  end

  defp channel_visible_to_names?(state, connection, {channel, members}) do
    channel_modes = Map.get(state.channel_modes, channel, MapSet.new())

    not (MapSet.member?(channel_modes, "s") or MapSet.member?(channel_modes, "p")) or
      MapSet.member?(members, connection)
  end

  defp names_channel_visible(state, connection, channel) do
    members = Map.get(state.channels, channel, MapSet.new())
    channel_modes = Map.get(state.channel_modes, channel, MapSet.new())

    multi_prefix? =
      "multi-prefix" in Map.get(state.connection_capabilities, connection, MapSet.new())

    userhost_in_names? =
      "userhost-in-names" in Map.get(state.connection_capabilities, connection, MapSet.new())

    names =
      members
      |> Enum.map(fn member ->
        nick = state.connections[member].nick

        name_prefixes =
          if multi_prefix? do
            Enum.join(
              if(channel_operator?(state, channel, member), do: ["@"], else: []) ++
                if(channel_voiced?(state, channel, member), do: ["+"], else: []),
              ""
            )
          else
            cond do
              channel_operator?(state, channel, member) -> "@"
              channel_voiced?(state, channel, member) -> "+"
              true -> ""
            end
          end

        name =
          if userhost_in_names? do
            client = state.connections[member]
            "#{nick}!#{client.username}@#{state.server_name}"
          else
            nick
          end

        name_prefixes <> name
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    names_message = %Ircxd.Message{
      source: state.server_name,
      command: "353",
      params: [state.connections[connection].nick, names_symbol(channel_modes), channel, names]
    }

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "366",
      params: [state.connections[connection].nick, channel, "End of NAMES list"]
    }

    state = broadcast(state, MapSet.new([connection]), names_message, connection)
    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp message_recipients(state, connection, target) do
    case Map.fetch(state.channels, target) do
      {:ok, members} ->
        channel_modes = Map.get(state.channel_modes, target, MapSet.new(["n"]))

        cond do
          not MapSet.member?(members, connection) and MapSet.member?(channel_modes, "n") ->
            {:error, "404",
             [state.connections[connection].nick, target, "Cannot send to channel"]}

          MapSet.member?(channel_modes, "m") and
            not channel_operator?(state, target, connection) and
              not channel_voiced?(state, target, connection) ->
            {:error, "404",
             [state.connections[connection].nick, target, "Cannot send to channel"]}

          true ->
            {:ok, members}
        end

      :error ->
        case find_connection_by_nick(state, target) do
          {recipient, _client} ->
            {:ok, MapSet.new([recipient])}

          nil ->
            if valid_channel?(target) do
              {:error, "403", [state.connections[connection].nick, target, "No such channel"]}
            else
              {:error, "401",
               [state.connections[connection].nick, target, "No such nick/channel"]}
            end
        end
    end
  end

  defp message_targets(target) do
    case String.split(target, ",", trim: true) do
      [] -> [target]
      targets -> targets
    end
  end

  defp echo_recipients(state, connection, recipients) do
    active = Map.get(state.connection_capabilities, connection, MapSet.new())

    if MapSet.member?(active, "echo-message"),
      do: recipients,
      else: MapSet.delete(recipients, connection)
  end

  defp join_channel(state, connection, channel, key) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
        if valid_channel?(channel) do
          source = source_for(client, state.server_name)
          account = if is_nil(client.account), do: "*", else: format_account(client.account)
          realname = client.realname || ""

          message = %Ircxd.Message{
            source: source,
            command: "JOIN",
            params: [channel, account, realname]
          }

          members = Map.get(state.channels, channel, MapSet.new())

          if MapSet.member?(members, connection) do
            state
          else
            invite_only? =
              MapSet.member?(Map.get(state.channel_modes, channel, MapSet.new()), "i")

            invited? = MapSet.member?(Map.get(state.invites, channel, MapSet.new()), connection)
            banned? = channel_banned?(state, channel, client)

            key_required? =
              MapSet.member?(Map.get(state.channel_modes, channel, MapSet.new()), "k")

            key_valid? = not key_required? or key == Map.get(state.channel_keys, channel)
            channel_limit = Map.get(state.channel_limits, channel)
            limit_reached? = is_integer(channel_limit) and MapSet.size(members) >= channel_limit

            cond do
              banned? ->
                error_reply(state, connection, "474", [nick, channel, "Cannot join channel (+b)"])

              limit_reached? ->
                error_reply(state, connection, "471", [nick, channel, "Cannot join channel (+l)"])

              not key_valid? ->
                error_reply(state, connection, "475", [nick, channel, "Cannot join channel (+k)"])

              invite_only? and not invited? ->
                error_reply(state, connection, "473", [nick, channel, "Cannot join channel (+i)"])

              true ->
                recipients = MapSet.put(members, connection)
                state = broadcast(state, recipients, message, connection)
                channels = Map.put(state.channels, channel, recipients)
                client_channels = MapSet.put(client.channels, channel)

                connections =
                  Map.update!(
                    state.connections,
                    connection,
                    &Map.put(&1, :channels, client_channels)
                  )

                invites =
                  Map.update(state.invites, channel, MapSet.new(), &MapSet.delete(&1, connection))

                channel_operators =
                  Map.update(
                    state.channel_operators,
                    channel,
                    MapSet.new([connection]),
                    fn operators ->
                      if MapSet.size(operators) == 0,
                        do: MapSet.new([connection]),
                        else: operators
                    end
                  )

                state = %{
                  state
                  | channels: channels,
                    channel_index:
                      Map.put(state.channel_index, fold_name(state, channel), channel),
                    connections: connections,
                    channel_operators: channel_operators,
                    channel_modes: Map.put_new(state.channel_modes, channel, MapSet.new(["n"])),
                    invites: invites
                }

                maybe_implicit_names(state, connection, channel)
            end
          end
        else
          error_reply(state, connection, "403", [nick, channel, "No such channel"])
        end

      _ ->
        state
    end
  end

  defp maybe_implicit_names(state, connection, channel) do
    active = Map.get(state.connection_capabilities, connection, MapSet.new())

    if MapSet.member?(active, "no-implicit-names"),
      do: state,
      else: names_channel(state, connection, channel)
  end

  defp capability_enabled?(state, connection, capability) do
    MapSet.member?(Map.get(state.connection_capabilities, connection, MapSet.new()), capability)
  end

  defp part_channel(state, connection, channel, rest) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
        members = Map.get(state.channels, channel, MapSet.new())

        if MapSet.member?(members, connection) do
          source = source_for(client, state.server_name)
          message = %Ircxd.Message{source: source, command: "PART", params: [channel | rest]}
          state = broadcast(state, members, message, connection)
          channels = Map.put(state.channels, channel, MapSet.delete(members, connection))
          client_channels = MapSet.delete(client.channels, channel)

          connections =
            Map.update!(state.connections, connection, &Map.put(&1, :channels, client_channels))

          state = %{state | channels: channels, connections: connections}
          state = remove_channel_voice(state, channel, connection)

          state
          |> update_channel_operators(channel, Map.get(channels, channel, MapSet.new()))
          |> cleanup_empty_channel(channel)
        else
          error_reply(state, connection, "442", [nick, channel, "You're not on that channel"])
        end

      _ ->
        state
    end
  end

  defp kick_member(state, connection, channel, target, rest) do
    requester = state.connections[connection].nick
    members = Map.get(state.channels, channel, MapSet.new())

    cond do
      not MapSet.member?(members, connection) ->
        error_reply(state, connection, "442", [requester, channel, "You're not on that channel"])

      not channel_operator?(state, channel, connection) ->
        error_reply(state, connection, "482", [requester, "You're not channel operator"])

      not nick_online?(state, target) ->
        error_reply(state, connection, "401", [requester, target, "No such nick/channel"])

      true ->
        {target_connection, target_client} = find_connection_by_nick(state, target)

        if MapSet.member?(members, target_connection) do
          client = state.connections[connection]

          message = %Ircxd.Message{
            source: source_for(client, state.server_name),
            command: "KICK",
            params: [channel, target | rest]
          }

          state = broadcast(state, members, message, connection)
          channels = Map.put(state.channels, channel, MapSet.delete(members, target_connection))

          connections =
            Map.put(
              state.connections,
              target_connection,
              %{target_client | channels: MapSet.delete(target_client.channels, channel)}
            )

          state = %{state | channels: channels, connections: connections}
          state = remove_channel_voice(state, channel, target_connection)

          state
          |> update_channel_operators(channel, Map.get(channels, channel, MapSet.new()))
          |> cleanup_empty_channel(channel)
        else
          error_reply(state, connection, "441", [requester, target, "They aren't on that channel"])
        end
    end
  end

  defp invite_member(state, connection, target, channel) do
    requester = state.connections[connection].nick
    members = Map.get(state.channels, channel, MapSet.new())

    cond do
      not MapSet.member?(members, connection) ->
        error_reply(state, connection, "442", [requester, channel, "You're not on that channel"])

      not Map.has_key?(state.channels, channel) ->
        error_reply(state, connection, "403", [requester, channel, "No such channel"])

      MapSet.member?(Map.get(state.channel_modes, channel, MapSet.new()), "i") and
          not channel_operator?(state, channel, connection) ->
        error_reply(state, connection, "482", [requester, "You're not channel operator"])

      true ->
        case find_connection_by_nick(state, target) do
          nil ->
            error_reply(state, connection, "401", [requester, target, "No such nick/channel"])

          {target_connection, _target_client} ->
            invites =
              Map.update(
                state.invites,
                channel,
                MapSet.new([target_connection]),
                &MapSet.put(&1, target_connection)
              )

            inviting = %Ircxd.Message{
              source: state.server_name,
              command: "341",
              params: [requester, target, channel]
            }

            state = broadcast(state, MapSet.new([connection]), inviting, connection)

            invite = %Ircxd.Message{
              source: source_for(state.connections[connection], state.server_name),
              command: "INVITE",
              params: [target, channel]
            }

            state = %{state | invites: invites}
            state = broadcast(state, MapSet.new([target_connection]), invite, connection)

            notify_recipients =
              members
              |> Enum.filter(&capability_enabled?(state, &1, "invite-notify"))
              |> MapSet.new()
              |> MapSet.delete(target_connection)

            broadcast(state, notify_recipients, invite, connection)
        end
    end
  end

  defp set_channel_mode(state, connection, channel, modes, mode_params) do
    nick = state.connections[connection].nick
    members = Map.get(state.channels, channel, MapSet.new())

    cond do
      not Map.has_key?(state.channels, channel) ->
        error_reply(state, connection, "403", [nick, channel, "No such channel"])

      not MapSet.member?(members, connection) ->
        error_reply(state, connection, "442", [nick, channel, "You're not on that channel"])

      not channel_operator?(state, channel, connection) ->
        error_reply(state, connection, "482", [nick, "You're not channel operator"])

      true ->
        cond do
          modes in ["+v", "-v"] ->
            set_channel_voice(state, connection, channel, modes, mode_params)

          modes in ["+o", "-o"] ->
            set_channel_operator(state, connection, channel, modes, mode_params)

          modes in ["+b", "-b"] ->
            set_channel_ban(state, connection, channel, modes, mode_params)

          true ->
            apply_channel_modes_to_channel(state, connection, channel, modes, mode_params)
        end
    end
  end

  defp apply_channel_modes_to_channel(state, connection, channel, modes, mode_params) do
    nick = state.connections[connection].nick
    members = Map.get(state.channels, channel, MapSet.new())

    case apply_channel_modes(
           Map.get(state.channel_modes, channel, MapSet.new()),
           modes,
           mode_params,
           Map.get(state.channel_keys, channel),
           Map.get(state.channel_limits, channel)
         ) do
      {:ok, channel_modes, channel_key, channel_limit} ->
        message = %Ircxd.Message{
          source: source_for(state.connections[connection], state.server_name),
          command: "MODE",
          params: [channel, modes]
        }

        channel_keys =
          if is_nil(channel_key),
            do: Map.delete(state.channel_keys, channel),
            else: Map.put(state.channel_keys, channel, channel_key)

        channel_limits =
          if is_nil(channel_limit),
            do: Map.delete(state.channel_limits, channel),
            else: Map.put(state.channel_limits, channel, channel_limit)

        state = %{
          state
          | channel_modes: Map.put(state.channel_modes, channel, channel_modes),
            channel_keys: channel_keys,
            channel_limits: channel_limits
        }

        broadcast(state, members, message, connection)

      {:error, :need_param} ->
        error_reply(state, connection, "461", [nick, "MODE", "Not enough parameters"])

      {:error, mode} ->
        error_reply(state, connection, "472", [
          nick,
          mode,
          "is an unknown mode character to me"
        ])
    end
  end

  defp set_channel_voice(state, connection, channel, modes, mode_params) do
    nick = state.connections[connection].nick

    case List.first(mode_params) do
      nil ->
        error_reply(state, connection, "461", [nick, "MODE", "Not enough parameters"])

      target ->
        case find_connection_by_nick(state, target) do
          nil ->
            error_reply(state, connection, "401", [nick, target, "No such nick/channel"])

          {target_connection, _target_client} ->
            members = Map.get(state.channels, channel, MapSet.new())

            if MapSet.member?(members, target_connection) do
              voices = Map.get(state.channel_voices, channel, MapSet.new())

              voices =
                if modes == "+v",
                  do: MapSet.put(voices, target_connection),
                  else: MapSet.delete(voices, target_connection)

              message = %Ircxd.Message{
                source: source_for(state.connections[connection], state.server_name),
                command: "MODE",
                params: [channel, modes, target]
              }

              state = %{state | channel_voices: Map.put(state.channel_voices, channel, voices)}
              broadcast(state, members, message, connection)
            else
              error_reply(state, connection, "441", [nick, target, "They aren't on that channel"])
            end
        end
    end
  end

  defp set_channel_operator(state, connection, channel, modes, mode_params) do
    nick = state.connections[connection].nick

    case List.first(mode_params) do
      nil ->
        error_reply(state, connection, "461", [nick, "MODE", "Not enough parameters"])

      target ->
        case find_connection_by_nick(state, target) do
          nil ->
            error_reply(state, connection, "401", [nick, target, "No such nick/channel"])

          {target_connection, _target_client} ->
            members = Map.get(state.channels, channel, MapSet.new())

            if MapSet.member?(members, target_connection) do
              operators = Map.get(state.channel_operators, channel, MapSet.new())

              operators =
                if modes == "+o",
                  do: MapSet.put(operators, target_connection),
                  else: MapSet.delete(operators, target_connection)

              message = %Ircxd.Message{
                source: source_for(state.connections[connection], state.server_name),
                command: "MODE",
                params: [channel, modes, target]
              }

              state = %{
                state
                | channel_operators: Map.put(state.channel_operators, channel, operators)
              }

              broadcast(state, members, message, connection)
            else
              error_reply(state, connection, "441", [nick, target, "They aren't on that channel"])
            end
        end
    end
  end

  defp set_channel_ban(state, connection, channel, modes, [mask]) when is_binary(mask) do
    bans = Map.get(state.channel_bans, channel, MapSet.new())

    bans =
      if modes == "+b",
        do: MapSet.put(bans, mask),
        else: MapSet.delete(bans, mask)

    message = %Ircxd.Message{
      source: source_for(state.connections[connection], state.server_name),
      command: "MODE",
      params: [channel, modes, mask]
    }

    state = %{state | channel_bans: Map.put(state.channel_bans, channel, bans)}
    broadcast(state, Map.get(state.channels, channel, MapSet.new()), message, connection)
  end

  defp set_channel_ban(state, connection, channel, "+b", []) do
    nick = state.connections[connection].nick
    bans = Map.get(state.channel_bans, channel, MapSet.new())

    state =
      Enum.reduce(bans, state, fn mask, state ->
        message = %Ircxd.Message{
          source: state.server_name,
          command: "367",
          params: [nick, channel, mask]
        }

        broadcast(state, MapSet.new([connection]), message, connection)
      end)

    end_message = %Ircxd.Message{
      source: state.server_name,
      command: "368",
      params: [nick, channel, "End of channel ban list"]
    }

    broadcast(state, MapSet.new([connection]), end_message, connection)
  end

  defp set_channel_ban(state, connection, _channel, _modes, _mode_params) do
    error_reply(state, connection, "461", [
      state.connections[connection].nick,
      "MODE",
      "Not enough parameters"
    ])
  end

  defp apply_channel_modes(
         channel_modes,
         <<sign::binary-size(1), modes::binary>>,
         params,
         key,
         limit
       )
       when sign in ["+", "-"] do
    modes
    |> String.graphemes()
    |> Enum.reduce_while({:ok, channel_modes, key, limit}, fn mode,
                                                              {:ok, current, current_key,
                                                               current_limit} ->
      cond do
        mode in ["i", "m", "n", "p", "s", "t"] ->
          next =
            if sign == "+" do
              current = MapSet.delete(current, if(mode == "p", do: "s", else: "p"))
              MapSet.put(current, mode)
            else
              MapSet.delete(current, mode)
            end

          {:cont, {:ok, next, current_key, current_limit}}

        mode == "k" and sign == "+" and is_binary(List.first(params)) ->
          {:cont, {:ok, MapSet.put(current, mode), List.first(params), current_limit}}

        mode == "k" and sign == "+" ->
          {:halt, {:error, :need_param}}

        mode == "k" and sign == "-" ->
          {:cont, {:ok, MapSet.delete(current, mode), nil, current_limit}}

        mode == "l" and sign == "+" ->
          case Integer.parse(to_string(List.first(params))) do
            {next_limit, ""} when next_limit > 0 ->
              {:cont, {:ok, MapSet.put(current, mode), current_key, next_limit}}

            _ ->
              {:halt, {:error, :invalid_limit}}
          end

        mode == "l" and sign == "-" ->
          {:cont, {:ok, MapSet.delete(current, mode), current_key, nil}}

        true ->
          {:halt, {:error, mode}}
      end
    end)
  end

  defp apply_channel_modes(_channel_modes, _modes, _params, _key, _limit), do: {:error, "?"}

  defp channel_mode_string(state, channel),
    do: channel_mode_string(Map.get(state.channel_modes, channel, MapSet.new()))

  defp channel_mode_string(channel_modes) do
    case channel_modes |> MapSet.to_list() |> Enum.sort() |> Enum.join() do
      "" -> "+"
      modes -> "+" <> modes
    end
  end

  defp names_symbol(channel_modes) do
    cond do
      MapSet.member?(channel_modes, "s") -> "@"
      MapSet.member?(channel_modes, "p") -> "*"
      true -> "="
    end
  end

  defp channel_operator?(state, channel, connection) do
    MapSet.member?(Map.get(state.channel_operators, channel, MapSet.new()), connection)
  end

  defp channel_voiced?(state, channel, connection) do
    MapSet.member?(Map.get(state.channel_voices, channel, MapSet.new()), connection)
  end

  defp channel_banned?(state, channel, client) do
    masks = [client.nick, source_for(client, state.server_name)]

    Enum.any?(Map.get(state.channel_bans, channel, MapSet.new()), fn mask ->
      Enum.any?(masks, &casemapped_wildcard_match?(state, mask, &1))
    end)
  end

  defp whowas_count([count | _rest]) when is_binary(count) do
    case Integer.parse(count) do
      {count, ""} when count > 0 -> min(count, 10)
      _ -> 1
    end
  end

  defp whowas_count(_rest), do: 1

  defp record_whowas(state, nick, _client) when not is_binary(nick), do: state

  defp record_whowas(state, nick, client) do
    entry = %{
      nick: nick,
      username: client.username || nick,
      host: "user",
      realname: client.realname || nick
    }

    nick_key = fold_name(state, nick)
    history = [entry | Map.get(state.whowas, nick_key, [])] |> Enum.take(10)
    %{state | whowas: Map.put(state.whowas, nick_key, history)}
  end

  defp wildcard_match?(mask, value) when is_binary(mask) and is_binary(value) do
    wildcard_match?(String.graphemes(mask), String.graphemes(value))
  end

  defp wildcard_match?([], []), do: true
  defp wildcard_match?([], _value), do: false
  defp wildcard_match?(["*" | rest], []), do: wildcard_match?(rest, [])

  defp wildcard_match?(["*" | rest], [_character | value]) do
    wildcard_match?(rest, value) or wildcard_match?(["*" | rest], value)
  end

  defp wildcard_match?(["?" | rest], [_character | value]), do: wildcard_match?(rest, value)
  defp wildcard_match?([character | rest], [character | value]), do: wildcard_match?(rest, value)
  defp wildcard_match?(_mask, _value), do: false

  defp casemapped_wildcard_match?(state, mask, value) do
    wildcard_match?(fold_name(state, mask), fold_name(state, value))
  end

  defp remove_channel_voice(state, channel, connection) do
    voices = MapSet.delete(Map.get(state.channel_voices, channel, MapSet.new()), connection)
    %{state | channel_voices: Map.put(state.channel_voices, channel, voices)}
  end

  defp update_channel_operators(state, channel, members) do
    operators =
      state.channel_operators
      |> Map.get(channel, MapSet.new())
      |> MapSet.intersection(members)

    operators =
      if MapSet.size(operators) == 0 and MapSet.size(members) > 0 do
        MapSet.new([Enum.at(MapSet.to_list(members), 0)])
      else
        operators
      end

    %{state | channel_operators: Map.put(state.channel_operators, channel, operators)}
  end

  defp cleanup_empty_channel(state, channel) do
    if MapSet.size(Map.get(state.channels, channel, MapSet.new())) == 0 do
      %{
        state
        | channels: Map.delete(state.channels, channel),
          channel_index: Map.delete(state.channel_index, fold_name(state, channel)),
          channel_operators: Map.delete(state.channel_operators, channel),
          channel_voices: Map.delete(state.channel_voices, channel),
          channel_modes: Map.delete(state.channel_modes, channel),
          invites: Map.delete(state.invites, channel),
          topics: Map.delete(state.topics, channel),
          channel_keys: Map.delete(state.channel_keys, channel),
          channel_limits: Map.delete(state.channel_limits, channel),
          channel_bans: Map.delete(state.channel_bans, channel)
      }
    else
      state
    end
  end

  defp add_message_id(state, recipients, %Ircxd.Message{} = message) do
    tagged_recipient? =
      Enum.any?(recipients, fn connection ->
        "message-tags" in Map.get(state.connection_capabilities, connection, MapSet.new())
      end)

    if tagged_recipient? and not Map.has_key?(message.tags, "msgid") do
      next_id = state.message_id + 1
      msgid = Integer.to_string(next_id, 16) |> String.upcase()
      {%{state | message_id: next_id}, %{message | tags: Map.put(message.tags, "msgid", msgid)}}
    else
      {state, message}
    end
  end

  defp add_account_tag(state, recipients, %Ircxd.Message{} = message, sender) do
    account_tag_recipient? =
      Enum.any?(recipients, fn connection ->
        "account-tag" in Map.get(state.connection_capabilities, connection, MapSet.new())
      end)

    account = get_in(state.connections, [sender, :account])

    if account_tag_recipient? and not is_nil(account) and
         not Map.has_key?(message.tags, "account") do
      %{message | tags: Map.put(message.tags, "account", format_account(account))}
    else
      message
    end
  end

  defp broadcast(state, recipients, message, sender) do
    metadata = %{
      server: state.server_name,
      connection: sender,
      recipients: MapSet.to_list(recipients)
    }

    message = add_account_tag(state, recipients, message, sender)
    {state, message} = add_message_id(state, recipients, message)
    state = dispatch_to_subscriber(state, message, metadata)
    Enum.each(recipients, &send(&1, {:server_send, message}))
    state
  end

  defp maybe_start_batch(state, connection, tags, recipients) do
    case Map.get(tags, "batch") do
      nil ->
        state

      ref ->
        case Map.fetch(state.batches, {connection, ref}) do
          {:ok, %{message: message, recipients: current} = batch} ->
            new_recipients = MapSet.difference(recipients, current)
            state = broadcast(state, new_recipients, message, connection)

            batches =
              Map.put(state.batches, {connection, ref}, %{
                batch
                | recipients: MapSet.union(current, new_recipients)
              })

            %{state | batches: batches}

          :error ->
            state
        end
    end
  end

  defp serve_history(state, connection, query, target, selector, limit)
       when query in ["LATEST", "BEFORE", "AFTER", "AROUND", "BETWEEN"] do
    requester = state.connections[connection].nick

    cond do
      not Map.has_key?(state.channels, target) ->
        error_reply(state, connection, "403", [requester, target, "No such channel"])

      not MapSet.member?(Map.get(state.channels, target), connection) ->
        error_reply(state, connection, "442", [requester, target, "You're not on that channel"])

      true ->
        entries = select_history(state.history, query, target, selector, limit)

        ref = "history-#{Integer.to_string(state.message_id + 1, 16)}"

        start_message = %Ircxd.Message{
          source: state.server_name,
          command: "BATCH",
          params: ["+#{ref}", "chathistory", target]
        }

        state = broadcast(state, MapSet.new([connection]), start_message, connection)

        state =
          Enum.reduce(entries, state, fn entry, state ->
            message = %{entry | tags: Map.put(entry.tags, "batch", ref)}
            broadcast(state, MapSet.new([connection]), message, nil)
          end)

        end_message = %Ircxd.Message{
          source: state.server_name,
          command: "BATCH",
          params: ["-#{ref}"]
        }

        broadcast(state, MapSet.new([connection]), end_message, connection)
    end
  end

  defp serve_history_targets(state, connection, first_selector, second_selector, limit) do
    visible_channels =
      state.channels
      |> Enum.filter(fn {_channel, members} -> MapSet.member?(members, connection) end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    targets =
      state.history
      |> Enum.filter(fn %{params: [channel, _body]} -> channel in visible_channels end)
      |> Enum.reduce(%{}, fn %{params: [channel, _body], tags: tags}, latest ->
        Map.put_new(latest, channel, Map.get(tags, "time"))
      end)
      |> Enum.filter(fn {_channel, timestamp} ->
        timestamp >= selector_value(first_selector) and
          timestamp <= selector_value(second_selector)
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(limit)

    target_messages =
      Enum.map(targets, fn {channel, timestamp} ->
        %Ircxd.Message{
          source: state.server_name,
          command: "CHATHISTORY",
          params: ["TARGETS", channel, timestamp]
        }
      end)

    if capability_enabled?(state, connection, "batch") do
      ref = "targets-#{Integer.to_string(state.message_id + 1, 16)}"

      start_message = %Ircxd.Message{
        source: state.server_name,
        command: "BATCH",
        params: ["+#{ref}", "draft/chathistory-targets"]
      }

      state = broadcast(state, MapSet.new([connection]), start_message, connection)

      state =
        Enum.reduce(
          target_messages,
          state,
          &broadcast(&2, MapSet.new([connection]), &1, connection)
        )

      end_message = %Ircxd.Message{
        source: state.server_name,
        command: "BATCH",
        params: ["-#{ref}"]
      }

      broadcast(state, MapSet.new([connection]), end_message, connection)
    else
      Enum.reduce(
        target_messages,
        state,
        &broadcast(&2, MapSet.new([connection]), &1, connection)
      )
    end
  end

  defp redact_message(state, connection, target, msgid, reason) do
    requester = state.connections[connection]

    cond do
      not valid_channel?(target) or not Map.has_key?(state.channels, target) ->
        redaction_error(state, connection, "INVALID_TARGET", target, msgid)

      not MapSet.member?(Map.get(state.channels, target), connection) ->
        redaction_error(state, connection, "INVALID_TARGET", target, msgid)

      true ->
        case Enum.find_index(state.history, fn
               %{params: [^target, _body], tags: %{"msgid" => ^msgid}} -> true
               _entry -> false
             end) do
          nil ->
            redaction_error(state, connection, "UNKNOWN_MSGID", target, msgid)

          index ->
            entry = Enum.at(state.history, index)

            authorized? =
              entry.source == source_for(requester, state.server_name) or
                channel_operator?(state, target, connection)

            if authorized? do
              history = List.delete_at(state.history, index)
              state = %{state | history: history}
              members = Map.get(state.channels, target, MapSet.new())
              recipients = capability_recipients(members, state, "draft/message-redaction")
              params = [target, msgid] ++ if(is_nil(reason), do: [], else: [reason])

              message = %Ircxd.Message{
                source: source_for(requester, state.server_name),
                command: "REDACT",
                params: params
              }

              broadcast(state, recipients, message, connection)
            else
              redaction_error(state, connection, "REDACT_FORBIDDEN", target, msgid)
            end
        end
    end
  end

  defp redaction_error(state, connection, code, target, msgid) do
    error_reply(state, connection, "FAIL", [
      "REDACT",
      code,
      target,
      msgid,
      "Redaction request was not permitted"
    ])
  end

  defp selector_value("timestamp=" <> timestamp), do: timestamp
  defp selector_value("msgid=" <> msgid), do: msgid
  defp selector_value(_selector), do: ""

  defp select_history(history, "LATEST", target, selector, limit) do
    select_latest_history(channel_history(history, target), selector, limit)
  end

  defp select_history(history, query, target, selector, limit)
       when query in ["BEFORE", "AFTER"] do
    entries = history |> channel_history(target) |> Enum.reverse()

    case Enum.find_index(entries, &history_selector_match?(&1, selector)) do
      nil -> []
      index when query == "BEFORE" -> entries |> Enum.take(index) |> Enum.take(-limit)
      index -> entries |> Enum.drop(index + 1) |> Enum.take(limit)
    end
  end

  defp select_history(history, "AROUND", target, selector, limit) do
    entries = history |> channel_history(target) |> Enum.reverse()

    case Enum.find_index(entries, &history_selector_match?(&1, selector)) do
      nil ->
        []

      index ->
        before = div(max(limit - 1, 0), 2)
        Enum.slice(entries, max(index - before, 0), limit)
    end
  end

  defp select_history(history, "BETWEEN", target, {first_selector, second_selector}, limit) do
    entries = history |> channel_history(target) |> Enum.reverse()

    with first when is_integer(first) <-
           Enum.find_index(entries, &history_selector_match?(&1, first_selector)),
         second when is_integer(second) <-
           Enum.find_index(entries, &history_selector_match?(&1, second_selector)) do
      {start, finish} = Enum.min_max([first, second])
      entries |> Enum.slice(start + 1, max(finish - start - 1, 0)) |> Enum.take(limit)
    else
      _ -> []
    end
  end

  defp select_latest_history(entries, "*", limit),
    do: entries |> Enum.take(limit) |> Enum.reverse()

  defp select_latest_history(entries, selector, limit) do
    entries = Enum.reverse(entries)

    case Enum.find_index(entries, &history_selector_match?(&1, selector)) do
      nil -> []
      index -> entries |> Enum.drop(index + 1) |> Enum.take(limit)
    end
  end

  defp channel_history(history, target) do
    Enum.filter(history, fn
      %{params: [^target, _body]} -> true
      _entry -> false
    end)
  end

  defp history_selector_match?(_entry, "*"), do: false

  defp history_selector_match?(%{tags: tags}, "msgid=" <> msgid),
    do: Map.get(tags, "msgid") == msgid

  defp history_selector_match?(%{tags: tags}, "timestamp=" <> timestamp),
    do: Map.get(tags, "time") == timestamp

  defp history_selector_match?(_entry, _selector), do: false

  defp record_history(state, %Ircxd.Message{command: command, params: [target, _body]} = message)
       when command in ["PRIVMSG", "NOTICE"] do
    if valid_channel?(target) and Map.has_key?(state.channels, target) do
      message_id = state.message_id + 1

      tags =
        message.tags
        |> Map.put_new("msgid", Integer.to_string(message_id, 16) |> String.upcase())
        |> Map.put_new("time", DateTime.utc_now() |> DateTime.to_iso8601())

      history = [
        %{message | tags: tags}
        | Enum.take(state.history, max(state.history_limit - 1, 0))
      ]

      {%{state | history: history, message_id: message_id}, %{message | tags: tags}}
    else
      {state, message}
    end
  end

  defp record_history(state, message), do: {state, message}

  defp finish_batch(state, connection, ref, message) do
    case Map.pop(state.batches, {connection, ref}) do
      {nil, _batches} ->
        state

      {%{recipients: recipients}, batches} ->
        message = %{
          message
          | source: source_for(state.connections[connection], state.server_name)
        }

        state = %{state | batches: batches}
        broadcast(state, recipients, message, connection)
    end
  end

  defp source_for(%{nick: nick}, server_name), do: "#{nick}!user@#{server_name}"

  defp format_account(account) when is_binary(account), do: account
  defp format_account(account), do: to_string(account)

  defp valid_channel?(channel) when is_binary(channel) do
    byte_size(channel) > 1 and String.first(channel) in ["#", "&"]
  end

  defp valid_channel?(_channel), do: false

  defp channels_for_list(state, connection, []) do
    Enum.filter(Map.to_list(state.channels), &channel_visible_in_list?(state, connection, &1))
  end

  defp channels_for_list(state, connection, [targets | _]) do
    targets
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn mask ->
      state.channels
      |> Enum.filter(fn {channel, members} ->
        casemapped_wildcard_match?(state, mask, channel) and
          channel_visible_in_list?(state, connection, {channel, members})
      end)
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp channel_visible_in_list?(state, connection, {channel, members}) do
    channel_modes = Map.get(state.channel_modes, channel, MapSet.new())

    not (MapSet.member?(channel_modes, "s") or MapSet.member?(channel_modes, "p")) or
      MapSet.member?(members, connection)
  end

  defp error_reply(state, connection, command, params) do
    message = %Ircxd.Message{source: state.server_name, command: command, params: params}
    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp capability_recipients(recipients, state, capability) do
    Enum.reduce(recipients, MapSet.new(), fn connection, filtered ->
      active = Map.get(state.connection_capabilities, connection, MapSet.new())

      if MapSet.member?(active, capability),
        do: MapSet.put(filtered, connection),
        else: filtered
    end)
  end

  defp remove_connection(state, connection) do
    case Map.pop(state.connections, connection) do
      {nil, _connections} ->
        state

      {%{channels: client_channels, nick: nick} = client, connections} ->
        state = record_whowas(state, nick, client)

        channels =
          Enum.reduce(client_channels, state.channels, fn channel, channel_state ->
            case Map.get(channel_state, channel) do
              nil ->
                channel_state

              members ->
                members = MapSet.delete(members, connection)

                if MapSet.size(members) == 0,
                  do: Map.delete(channel_state, channel),
                  else: Map.put(channel_state, channel, members)
            end
          end)

        state = %{
          state
          | connections: connections,
            nick_index:
              if(is_binary(nick),
                do: Map.delete(state.nick_index, fold_name(state, nick)),
                else: state.nick_index
              ),
            channels: channels,
            batches:
              state.batches
              |> Enum.reject(fn {{batch_connection, _ref}, _batch} ->
                batch_connection == connection
              end)
              |> Map.new(),
            monitors: Map.delete(state.monitors, connection),
            connection_capabilities: Map.delete(state.connection_capabilities, connection)
        }

        state =
          Enum.reduce(client_channels, state, fn channel, state ->
            state = remove_channel_voice(state, channel, connection)

            state
            |> update_channel_operators(channel, Map.get(state.channels, channel, MapSet.new()))
            |> cleanup_empty_channel(channel)
          end)

        notify_monitors(state, nick, :offline)
    end
  end

  defp broadcast_disconnect(state, connection) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick, channels: channels}} when is_binary(nick) ->
        recipients =
          channels
          |> Enum.reduce(MapSet.new(), fn channel, recipients ->
            MapSet.union(recipients, Map.get(state.channels, channel, MapSet.new()))
          end)
          |> MapSet.delete(connection)

        message = %Ircxd.Message{
          source: source_for(%{nick: nick}, state.server_name),
          command: "QUIT",
          params: ["Connection closed"]
        }

        broadcast(state, recipients, message, connection)

      _ ->
        state
    end
  end

  defp accept_loop(:gen_tcp, listener, owner, handshake_supervisor, handshake_timeout) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, owner)
        send(owner, {:accepted, :gen_tcp, socket})
        accept_loop(:gen_tcp, listener, owner, handshake_supervisor, handshake_timeout)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:accept_error, reason})
    end
  end

  defp accept_loop(:ssl, listener, owner, handshake_supervisor, handshake_timeout) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case start_tls_handshake(
               handshake_supervisor,
               socket,
               owner,
               handshake_timeout
             ) do
          :ok ->
            accept_loop(:ssl, listener, owner, handshake_supervisor, handshake_timeout)

          {:error, _reason} ->
            :ssl.close(socket)
            accept_loop(:ssl, listener, owner, handshake_supervisor, handshake_timeout)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:accept_error, reason})
    end
  end

  defp start_tls_handshake(supervisor, socket, owner, timeout) do
    case Task.Supervisor.start_child(supervisor, fn ->
           receive do
             :start_handshake -> complete_tls_handshake(socket, owner, timeout)
           end
         end) do
      {:ok, worker} ->
        case :ssl.controlling_process(socket, worker) do
          :ok ->
            send(worker, :start_handshake)
            :ok

          {:error, reason} ->
            Process.exit(worker, :shutdown)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_tls_handshake(socket, owner, timeout) do
    case :ssl.handshake(socket, timeout) do
      :ok ->
        hand_off_tls_socket(socket, owner)

      {:ok, established_socket} ->
        hand_off_tls_socket(established_socket, owner)

      {:error, reason} ->
        :ssl.close(socket)
        send(owner, {:tls_handshake_error, reason})
    end
  end

  defp hand_off_tls_socket(socket, owner) do
    case :ssl.controlling_process(socket, owner) do
      :ok ->
        send(owner, {:accepted, :ssl, socket})

      {:error, reason} ->
        :ssl.close(socket)
        send(owner, {:tls_handshake_error, reason})
    end
  end
end
