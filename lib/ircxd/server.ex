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
         topics: %{},
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

      {:reply, :ok, %{state | connections: connections}}
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

  def handle_cast({:client_command, connection, message}, state) do
    {:noreply, handle_client_command(state, connection, message)}
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
              registered?: false,
              channels: MapSet.new()
            }

            {:noreply,
             %{state | connections: Map.put(state.connections, connection, connection_state)}}

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
    if auth_required?, do: ["message-tags", "sasl"], else: ["message-tags"]
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
         params: [channel]
       }) do
    channel
    |> String.split(",", trim: true)
    |> Enum.reduce(state, fn channel, state -> join_channel(state, connection, channel) end)
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
         command: "PART",
         params: [channel | rest]
       }) do
    channel
    |> String.split(",", trim: true)
    |> Enum.reduce(state, fn channel, state -> part_channel(state, connection, channel, rest) end)
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
      client = state.connections[connection]

      message = %Ircxd.Message{
        source: source_for(client, state.server_name),
        command: "TOPIC",
        params: [channel, topic]
      }

      state = broadcast(state, members, message, connection)
      %{state | topics: Map.put(state.topics, channel, topic)}
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
        recipients = recipients_for(state, target)
        source = source_for(client, state.server_name)

        message = %Ircxd.Message{
          tags: tags,
          source: source,
          command: command,
          params: [target, body]
        }

        broadcast(state, recipients, message, connection)

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
          params: [nick, target, "+"]
        }

        broadcast(state, MapSet.new([connection]), message, connection)

      valid_channel?(target) ->
        error_reply(state, connection, "403", [nick, target, "No such channel"])

      true ->
        error_reply(state, connection, "401", [nick, target, "No such nick/channel"])
    end
  end

  defp handle_registered_command(state, connection, %{command: command}) do
    error_reply(state, connection, "421", [
      state.connections[connection].nick,
      command,
      "Unknown command"
    ])
  end

  defp names_channel(state, connection, channel) do
    members = Map.get(state.channels, channel, MapSet.new())

    names =
      members
      |> Enum.map(&state.connections[&1].nick)
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

  defp join_channel(state, connection, channel) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
        if valid_channel?(channel) do
          source = source_for(client, state.server_name)
          message = %Ircxd.Message{source: source, command: "JOIN", params: [channel]}
          members = Map.get(state.channels, channel, MapSet.new())
          recipients = MapSet.put(members, connection)
          state = broadcast(state, recipients, message, connection)
          channels = Map.put(state.channels, channel, recipients)
          client_channels = MapSet.put(client.channels, channel)

          connections =
            Map.update!(state.connections, connection, &Map.put(&1, :channels, client_channels))

          %{state | channels: channels, connections: connections}
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

          %{state | channels: channels, connections: connections}
        else
          state
        end

      _ ->
        state
    end
  end

  defp broadcast(state, recipients, message, sender) do
    metadata = %{
      server: state.server_name,
      connection: sender,
      recipients: MapSet.to_list(recipients)
    }

    state = dispatch_to_subscriber(state, message, metadata)
    Enum.each(recipients, &send(&1, {:server_send, message}))
    state
  end

  defp source_for(%{nick: nick}, server_name), do: "#{nick}!user@#{server_name}"

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

  defp remove_connection(state, connection) do
    case Map.pop(state.connections, connection) do
      {nil, _connections} ->
        state

      {%{channels: channels}, connections} ->
        channels =
          Enum.reduce(channels, state.channels, fn channel, channel_state ->
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

        %{state | connections: connections, channels: channels}
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
