defmodule Ircxd.Server do
  @moduledoc """
  Embeddable IRC server.

  Add `{Ircxd.Server, port: 6667}` to an application's supervision tree. Each
  server owns its listener and connections, so multiple instances can run in
  the same VM.
  """

  use GenServer

  alias Ircxd.Server.Connection

  @default_server_name "ircxd.local"

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

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 6667)
    server_name = Keyword.get(opts, :server_name, @default_server_name)

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
         connections: %{},
         channels: %{},
         topics: %{},
         subscriber: init_subscriber(Keyword.get(opts, :subscriber)),
         authenticator: init_authenticator(Keyword.get(opts, :authenticator))
       }}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

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
           auth_required?: not is_nil(state.authenticator)
         ) do
      {:ok, connection} ->
        case :gen_tcp.controlling_process(socket, connection) do
          :ok ->
            send(connection, :activate)
            ref = Process.monitor(connection)
            connection_state = %{socket: socket, ref: ref, nick: nil, channels: MapSet.new()}

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
    {:noreply, %{state | connections: Map.delete(state.connections, connection)}}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.acceptor), do: Process.exit(state.acceptor, :shutdown)
    :gen_tcp.close(state.listener)
    Enum.each(Map.keys(state.connections), &Process.exit(&1, :shutdown))
  end

  defp listen(port) do
    :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])
  end

  defp init_subscriber(nil), do: nil

  defp init_subscriber({module, arg}) do
    {:ok, subscriber_state} = module.init(arg)
    %{module: module, state: subscriber_state}
  end

  defp init_authenticator(nil), do: nil

  defp init_authenticator({module, arg}) do
    {:ok, authenticator_state} = module.init(arg)
    %{module: module, state: authenticator_state}
  end

  defp dispatch_to_subscriber(%{subscriber: nil} = state, _message, _metadata), do: state

  defp dispatch_to_subscriber(%{subscriber: subscriber} = state, message, metadata) do
    case subscriber.module.handle_publish(message, metadata, subscriber.state) do
      {:ok, subscriber_state} -> %{state | subscriber: %{subscriber | state: subscriber_state}}
      _other -> state
    end
  rescue
    _error -> state
  end

  defp handle_client_command(state, connection, %{
         command: "JOIN",
         params: [channel]
       }) do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
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

      _ ->
        state
    end
  end

  defp handle_client_command(state, connection, %{
         command: "NAMES",
         params: [channel]
       }) do
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

  defp handle_client_command(state, connection, %{
         command: "PART",
         params: [channel | rest]
       }) do
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

  defp handle_client_command(state, connection, %{
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

  defp handle_client_command(state, connection, %{
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

  defp handle_client_command(state, connection, %{
         command: command,
         params: [target, body]
       })
       when command in ["PRIVMSG", "NOTICE"] do
    case Map.fetch(state.connections, connection) do
      {:ok, %{nick: nick} = client} when is_binary(nick) ->
        recipients = Map.get(state.channels, target, MapSet.new())
        source = source_for(client, state.server_name)
        message = %Ircxd.Message{source: source, command: command, params: [target, body]}
        broadcast(state, recipients, message, connection)

      _ ->
        state
    end
  end

  defp handle_client_command(state, _connection, _message), do: state

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
