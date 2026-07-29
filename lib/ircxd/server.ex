defmodule Ircxd.Server do
  @moduledoc """
  Embeddable IRC server.

  Add `{Ircxd.Server, id: :public_irc, port: 6667}` to an application's
  supervision tree. Each server owns its listener and connections, so multiple
  instances can run in the same VM when they have distinct child IDs.
  """

  use GenServer

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

  def command(server, connection, message),
    do: GenServer.cast(server, {:client_command, connection, message})

  def capabilities(server, connection, capabilities),
    do: GenServer.cast(server, {:client_capabilities, connection, capabilities})

  def identity(server, connection, username, realname),
    do: GenServer.cast(server, {:client_identity, connection, username, realname})

  def register(server, connection, nick),
    do: GenServer.call(server, {:register, connection, nick})

  def verify_password(server, password),
    do: GenServer.call(server, {:verify_password, password})

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 6667)
    server_name = Keyword.get(opts, :server_name, @default_server_name)
    password = Keyword.get(opts, :password)
    motd = normalize_motd(Keyword.get(opts, :motd, []))
    isupport = normalize_isupport(Keyword.get(opts, :isupport))
    admin = normalize_admin(Keyword.get(opts, :admin))
    authenticator = init_authenticator(Keyword.get(opts, :authenticator))

    with {:ok, listener} <- listen(port) do
      {:ok, {_address, actual_port}} = :inet.sockname(listener)
      owner = self()
      {:ok, acceptor} = Task.start(fn -> accept_loop(listener, owner) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         port: actual_port,
         server_name: server_name,
         password: password,
         motd: motd,
         isupport: isupport,
         admin: admin,
         registration_timeout: Keyword.get(opts, :registration_timeout, 60_000),
         connections: %{},
         channels: %{},
         channel_operators: %{},
         channel_voices: %{},
         channel_modes: %{},
         invites: %{},
         topics: %{},
         channel_keys: %{},
         channel_limits: %{},
         monitors: %{},
         connection_capabilities: %{},
         message_id: 0,
         capabilities: capabilities(not is_nil(authenticator)),
         subscriber: init_subscriber(Keyword.get(opts, :subscriber)),
         authenticator: authenticator
       }}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:register, connection, nick}, _from, state) do
    nick_in_use? =
      Enum.any?(state.connections, fn
        {pid, %{nick: ^nick}} when pid != connection -> true
        _ -> false
      end)

    if nick_in_use? do
      {:reply, {:error, :nick_in_use}, state}
    else
      connections =
        Map.update!(state.connections, connection, fn client ->
          %{client | nick: nick, registered?: true}
        end)

      state = %{state | connections: connections}
      state = notify_monitors(state, nick, :online)

      state =
        case state.connections[connection].account do
          nil -> state
          account -> notify_account(state, connection, account)
        end

      {:reply, :ok, state}
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
        case authenticator.module.authenticate(
               username,
               password,
               metadata,
               authenticator.state
             ) do
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

  def handle_cast({:client_command, connection, message}, state) do
    {:noreply, handle_client_command(state, connection, message)}
  end

  def handle_cast({:client_capabilities, connection, capabilities}, state) do
    {:noreply,
     %{
       state
       | connection_capabilities: Map.put(state.connection_capabilities, connection, capabilities)
     }}
  end

  @impl true
  def handle_info({:accepted, socket}, state) do
    case Connection.start(
           socket: socket,
           server: self(),
           server_name: state.server_name,
           isupport: state.isupport,
           password: state.password,
           registration_timeout: state.registration_timeout,
           auth_required?: not is_nil(state.authenticator),
           capabilities: state.capabilities
         ) do
      {:ok, connection} ->
        case :gen_tcp.controlling_process(socket, connection) do
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
            :gen_tcp.close(socket)
            {:stop, reason, state}
        end

      {:error, reason} ->
        :gen_tcp.close(socket)
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

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.acceptor), do: Process.exit(state.acceptor, :shutdown)
    :gen_tcp.close(state.listener)
    Enum.each(Map.keys(state.connections), &Process.exit(&1, :shutdown))

    if state.subscriber, do: GenServer.stop(state.subscriber.pid, :shutdown)
  end

  defp listen(port) do
    :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])
  end

  defp init_subscriber(nil), do: nil

  defp init_subscriber({module, arg}) do
    {:ok, pid} = SubscriberWorker.start(module, arg)
    %{pid: pid}
  end

  defp init_authenticator(nil), do: nil

  defp init_authenticator({module, arg}) do
    {:ok, authenticator_state} = module.init(arg)
    %{module: module, state: authenticator_state}
  end

  defp capabilities(auth_required?) do
    if auth_required?,
      do: [
        "message-tags",
        "server-time",
        "extended-join",
        "away-notify",
        "account-notify",
        "sasl"
      ],
      else: ["message-tags", "server-time", "extended-join", "away-notify", "account-notify"]
  end

  defp normalize_motd(motd) when is_binary(motd), do: String.split(motd, "\n")
  defp normalize_motd(motd) when is_list(motd), do: Enum.map(motd, &to_string/1)
  defp normalize_motd(_motd), do: []

  defp normalize_isupport(nil), do: ["CHANTYPES=#&", "NICKLEN=30", "CASEMAPPING=ascii"]

  defp normalize_isupport(tokens) when is_binary(tokens),
    do: String.split(tokens, " ", trim: true)

  defp normalize_isupport(tokens) when is_list(tokens), do: Enum.map(tokens, &to_string/1)
  defp normalize_isupport(_tokens), do: normalize_isupport(nil)

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
        handle_registered_command(state, connection, message)

      {:ok, %{nick: nick}} ->
        error_reply(state, connection, "451", [nick || "*", "You have not registered"])

      :error ->
        state
    end
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
    Enum.reduce(state.channels, state, fn {channel, _members}, state ->
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
        if Enum.any?(state.connections, fn {_pid, client} -> client.nick == target end),
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
        case Enum.find(state.connections, fn {_pid, client} -> client.nick == target end) do
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
    channels = channels_for_list(state, params)

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

  defp handle_registered_command(state, connection, %{
         command: "WHO",
         params: [mask | _rest]
       }) do
    requester = state.connections[connection].nick

    members =
      case Map.fetch(state.channels, mask) do
        {:ok, members} -> members
        :error -> MapSet.new()
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
            mask,
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

  defp handle_registered_command(state, connection, %{
         command: "WHOIS",
         params: [target | _rest]
       }) do
    requester = state.connections[connection].nick

    case Enum.find_value(state.connections, fn
           {_pid, %{nick: ^target} = client} -> client
           _other -> nil
         end) do
      nil ->
        error_reply(state, connection, "401", [requester, target, "No such nick/channel"])

      client ->
        username = client.username || client.nick
        realname = client.realname || client.nick

        user_message = %Ircxd.Message{
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
                source: state.server_name,
                command: "330",
                params: [requester, client.nick, format_account(account), "is logged in as"]
              }

              broadcast(state, MapSet.new([connection]), account_message, connection)
          end

        server_message = %Ircxd.Message{
          source: state.server_name,
          command: "312",
          params: [requester, client.nick, state.server_name, "Ircxd server"]
        }

        state = broadcast(state, MapSet.new([connection]), server_message, connection)

        end_message = %Ircxd.Message{
          source: state.server_name,
          command: "318",
          params: [requester, client.nick, "End of /WHOIS list"]
        }

        broadcast(state, MapSet.new([connection]), end_message, connection)
    end
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
         params: [channel, target | rest]
       }) do
    kick_member(state, connection, channel, target, rest)
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
      state
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
        case message_recipients(state, connection, target) do
          {:ok, recipients} ->
            source = source_for(client, state.server_name)

            message = %Ircxd.Message{
              tags: tags,
              source: source,
              command: command,
              params: [target, body]
            }

            broadcast(state, recipients, message, connection)

          {:error, error_command, params} when command == "PRIVMSG" ->
            error_reply(state, connection, error_command, params)

          {:error, _error_command, _params} ->
            state
        end

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
        recipients = recipients_for(state, target)
        source = source_for(client, state.server_name)
        message = %Ircxd.Message{tags: tags, source: source, command: "TAGMSG", params: [target]}
        broadcast(state, recipients, message, connection)

      _ ->
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

  defp handle_registered_command(state, connection, %{command: command}) do
    error_reply(state, connection, "421", [
      state.connections[connection].nick,
      command,
      "Unknown command"
    ])
  end

  defp handle_monitor_command(state, connection, "+", [targets]) do
    targets = String.split(targets, ",", trim: true)
    monitored = Map.get(state.monitors, connection, MapSet.new())
    monitored = Enum.reduce(targets, monitored, &MapSet.put(&2, &1))
    state = %{state | monitors: Map.put(state.monitors, connection, monitored)}
    nick = state.connections[connection].nick

    {online, offline} =
      Enum.split_with(targets, fn target ->
        Enum.any?(state.connections, fn {_pid, client} -> client.nick == target end)
      end)

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
    targets = String.split(targets, ",", trim: true)
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
      {_pid, client} =
        Enum.find(state.connections, fn {_pid, client} -> client.nick == target end)

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
    Enum.reduce(state.monitors, state, fn {watcher, targets}, state ->
      if MapSet.member?(targets, nick) and Map.has_key?(state.connections, watcher) do
        watcher_nick = state.connections[watcher].nick

        case status do
          :online ->
            target =
              Enum.find_value(state.connections, fn {_pid, client} ->
                if client.nick == nick, do: source_for(client, state.server_name)
              end)

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

    names =
      members
      |> Enum.map(fn member ->
        nick = state.connections[member].nick

        cond do
          channel_operator?(state, channel, member) -> "@" <> nick
          channel_voiced?(state, channel, member) -> "+" <> nick
          true -> nick
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    names_message = %Ircxd.Message{
      source: state.server_name,
      command: "353",
      params: [state.connections[connection].nick, "=", channel, names]
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
        cond do
          not MapSet.member?(members, connection) ->
            {:error, "404",
             [state.connections[connection].nick, target, "Cannot send to channel"]}

          MapSet.member?(Map.get(state.channel_modes, target, MapSet.new()), "m") and
            not channel_operator?(state, target, connection) and
              not channel_voiced?(state, target, connection) ->
            {:error, "404",
             [state.connections[connection].nick, target, "Cannot send to channel"]}

          true ->
            {:ok, members}
        end

      :error ->
        case Enum.find(state.connections, fn {_pid, client} -> client.nick == target end) do
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

            key_required? =
              MapSet.member?(Map.get(state.channel_modes, channel, MapSet.new()), "k")

            key_valid? = not key_required? or key == Map.get(state.channel_keys, channel)
            channel_limit = Map.get(state.channel_limits, channel)
            limit_reached? = is_integer(channel_limit) and MapSet.size(members) >= channel_limit

            cond do
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

                %{
                  state
                  | channels: channels,
                    connections: connections,
                    channel_operators: channel_operators,
                    invites: invites
                }
            end
          end
        else
          error_reply(state, connection, "403", [nick, channel, "No such channel"])
        end

      _ ->
        state
    end
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
          update_channel_operators(state, channel, Map.get(channels, channel, MapSet.new()))
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

      not Enum.any?(state.connections, fn {_pid, client} -> client.nick == target end) ->
        error_reply(state, connection, "401", [requester, target, "No such nick/channel"])

      true ->
        {target_connection, target_client} =
          Enum.find(state.connections, fn {_pid, client} -> client.nick == target end)

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
          update_channel_operators(state, channel, Map.get(channels, channel, MapSet.new()))
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

      true ->
        case Enum.find(state.connections, fn {_pid, client} -> client.nick == target end) do
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

            broadcast(
              %{state | invites: invites},
              MapSet.new([target_connection]),
              invite,
              connection
            )
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
        if modes in ["+v", "-v"] do
          set_channel_voice(state, connection, channel, modes, mode_params)
        else
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
        mode_string = channel_mode_string(channel_modes)

        message = %Ircxd.Message{
          source: source_for(state.connections[connection], state.server_name),
          command: "MODE",
          params: [channel, mode_string]
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
        case Enum.find(state.connections, fn {_pid, client} -> client.nick == target end) do
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
        mode in ["i", "m", "t"] ->
          next = if sign == "+", do: MapSet.put(current, mode), else: MapSet.delete(current, mode)
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

  defp channel_operator?(state, channel, connection) do
    MapSet.member?(Map.get(state.channel_operators, channel, MapSet.new()), connection)
  end

  defp channel_voiced?(state, channel, connection) do
    MapSet.member?(Map.get(state.channel_voices, channel, MapSet.new()), connection)
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

  defp broadcast(state, recipients, message, sender) do
    metadata = %{
      server: state.server_name,
      connection: sender,
      recipients: MapSet.to_list(recipients)
    }

    {state, message} = add_message_id(state, recipients, message)
    state = dispatch_to_subscriber(state, message, metadata)
    Enum.each(recipients, &send(&1, {:server_send, message}))
    state
  end

  defp source_for(%{nick: nick}, server_name), do: "#{nick}!user@#{server_name}"

  defp format_account(account) when is_binary(account), do: account
  defp format_account(account), do: to_string(account)

  defp valid_channel?(channel) when is_binary(channel) do
    byte_size(channel) > 1 and String.first(channel) in ["#", "&"]
  end

  defp valid_channel?(_channel), do: false

  defp channels_for_list(state, []), do: Map.to_list(state.channels)

  defp channels_for_list(state, [targets | _]) do
    targets
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn channel ->
      case Map.fetch(state.channels, channel) do
        {:ok, members} -> [{channel, members}]
        :error -> []
      end
    end)
  end

  defp error_reply(state, connection, command, params) do
    message = %Ircxd.Message{source: state.server_name, command: command, params: params}
    broadcast(state, MapSet.new([connection]), message, connection)
  end

  defp recipients_for(state, target) do
    case Map.fetch(state.channels, target) do
      {:ok, members} ->
        members

      :error ->
        state.connections
        |> Enum.find_value(MapSet.new(), fn
          {connection, %{nick: ^target}} -> MapSet.new([connection])
          _ -> nil
        end)
    end
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

      {%{channels: client_channels, nick: nick}, connections} ->
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
            channels: channels,
            monitors: Map.delete(state.monitors, connection),
            connection_capabilities: Map.delete(state.connection_capabilities, connection)
        }

        state =
          Enum.reduce(client_channels, state, fn channel, state ->
            state = remove_channel_voice(state, channel, connection)

            update_channel_operators(
              state,
              channel,
              Map.get(state.channels, channel, MapSet.new())
            )
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

  defp accept_loop(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, owner)
        send(owner, {:accepted, socket})
        accept_loop(listener, owner)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:accept_error, reason})
    end
  end
end
