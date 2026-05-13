defmodule Ircxd.ScriptedIrcServer do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(pid), do: GenServer.call(pid, :port)
  def lines(pid), do: GenServer.call(pid, :lines)

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    script = Keyword.get(opts, :script, &default_script/2)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    Task.start_link(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          :ok = :gen_tcp.controlling_process(socket, parent)
          send(parent, {:accepted, {:ok, socket}})

        {:error, reason} ->
          send(parent, {:accepted, {:error, reason}})
      end
    end)

    {:ok,
     %{listener: listener, socket: nil, test_pid: test_pid, script: script, lines: [], port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:lines, _from, state), do: {:reply, Enum.reverse(state.lines), state}

  @impl true
  def handle_info({:accepted, {:ok, socket}}, state) do
    send(self(), :read)
    {:noreply, %{state | socket: socket}}
  end

  def handle_info({:accepted, {:error, reason}}, state), do: {:stop, reason, state}

  def handle_info(:read, %{socket: socket} = state) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:ok, line} ->
        line = String.trim(line)
        send(state.test_pid, {:scripted_irc_line, line})
        state = %{state | lines: [line | state.lines]}
        Enum.each(state.script.(line, state), &:gen_tcp.send(socket, [&1, "\r\n"]))
        send(self(), :read)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :read)
        {:noreply, state}

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :gen_tcp.close(state.listener)
  end

  defp default_script(_line, _state), do: []
end
