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
            connection_state = %{socket: socket, ref: ref}

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
