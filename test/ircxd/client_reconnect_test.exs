defmodule Ircxd.ClientReconnectTest do
  use ExUnit.Case, async: false

  test "optionally reconnects after a transport close" do
    {:ok, server} = TwoConnectionServer.start_link(self())

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: TwoConnectionServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        reconnect: [max_attempts: 1, delay: 10],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, :disconnected}, 1_000
    assert_receive {:ircxd, {:reconnecting, %{attempt: 1, delay: 10}}}, 1_000
    assert_receive {:two_connection_line, 2, "CAP LS 302"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "intentional quit stays disconnected until explicitly reconnected" do
    {:ok, server} = IntentionalQuitServer.start_link(self())

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: IntentionalQuitServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        reconnect: [max_attempts: 2, delay: 10],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    old_socket = :sys.get_state(client).socket
    assert :ok = Ircxd.Client.quit(client, "done")
    assert_receive {:intentional_quit_line, 1, "QUIT done"}, 1_000
    assert_receive {:ircxd, :disconnected}, 1_000

    assert_receive {:ircxd,
                    {:disconnect, %{reason: :quit, intentional?: true, reconnecting?: false}}},
                   1_000

    assert %Ircxd.Client.Info{
             connected?: false,
             registered?: false,
             current_nick: nil,
             available_caps: %{},
             active_caps: active_caps,
             isupport: %{}
           } = Ircxd.Client.connection_info(client)

    assert active_caps == MapSet.new()

    refute_receive {:intentional_quit_line, 2, "CAP LS 302"}, 100
    assert Process.alive?(client)

    send(client, {:tcp_closed, old_socket})
    refute_receive {:intentional_quit_line, 2, "CAP LS 302"}, 100
    assert Process.alive?(client)

    assert :ok = Ircxd.Client.reconnect(client)
    assert_receive {:intentional_quit_line, 2, "CAP LS 302"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000

    assert_receive {:ircxd,
                    {:disconnect,
                     %{reason: :transport_closed, intentional?: false, reconnecting?: true}}},
                   1_000

    assert_receive {:ircxd, {:reconnecting, %{attempt: 1, delay: 10}}}, 1_000
    assert_receive {:intentional_quit_line, 3, "CAP LS 302"}, 1_000
  end

  test "reports bounded reconnect exhaustion and is not restarted by a supervisor" do
    {:ok, server} = ReconnectFailureServer.start_link(self())

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Ircxd.Client,
           [
             host: "127.0.0.1",
             port: ReconnectFailureServer.port(server),
             nick: "nick",
             username: "nick",
             realname: "Nick",
             reconnect: [max_attempts: 2, delay: 10],
             notify: self()
           ]}
        ],
        strategy: :one_for_one
      )

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    end)

    [{_id, client, :worker, _modules}] = Supervisor.which_children(supervisor)
    monitor = Process.monitor(client)

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:reconnecting, %{attempt: 1}}}, 1_000
    assert_receive {:ircxd, {:connect_error, _reason}}, 1_000
    assert_receive {:ircxd, {:reconnecting, %{attempt: 2}}}, 1_000
    assert_receive {:ircxd, {:connect_error, reason}}, 1_000

    assert_receive {:ircxd,
                    {:reconnect_exhausted, %{attempts: 2, max_attempts: 2, reason: ^reason}}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 1_000

    refute Enum.any?(Supervisor.which_children(supervisor), fn {_id, pid, _type, _modules} ->
             is_pid(pid)
           end)

    refute_receive {:ircxd, {:connect_error, _reason}}, 100
  end
end

defmodule TwoConnectionServer do
  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(test_pid) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    Task.start_link(fn -> accept_loop(listener, test_pid, 1) end)

    {:ok, %{listener: listener, port: port, test_pid: test_pid}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept_loop(listener, test_pid, connection) when connection <= 2 do
    {:ok, socket} = :gen_tcp.accept(listener)
    read_loop(socket, test_pid, connection)
    accept_loop(listener, test_pid, connection + 1)
  end

  defp accept_loop(_listener, _test_pid, _connection), do: :ok

  defp read_loop(socket, test_pid, connection) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, line} ->
        line = String.trim(line)
        send(test_pid, {:two_connection_line, connection, line})
        Enum.each(reply(line, connection), &:gen_tcp.send(socket, [&1, "\r\n"]))
        if line == "CAP END" and connection == 1, do: :gen_tcp.close(socket)
        read_loop(socket, test_pid, connection)

      {:error, _reason} ->
        :ok
    end
  end

  defp reply("CAP LS 302", _connection), do: [":irc.test CAP * LS :"]
  defp reply("CAP END", _connection), do: [":irc.test 001 nick :Welcome"]
  defp reply(_line, _connection), do: []
end

defmodule IntentionalQuitServer do
  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(test_pid) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    Task.start_link(fn -> accept_loop(listener, test_pid, 1) end)
    {:ok, %{listener: listener, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept_loop(listener, test_pid, connection) when connection <= 3 do
    {:ok, socket} = :gen_tcp.accept(listener)
    read_loop(socket, test_pid, connection)
    accept_loop(listener, test_pid, connection + 1)
  end

  defp accept_loop(_listener, _test_pid, _connection), do: :ok

  defp read_loop(socket, test_pid, connection) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, line} ->
        line = String.trim(line)
        send(test_pid, {:intentional_quit_line, connection, line})
        Enum.each(reply(line), &:gen_tcp.send(socket, [&1, "\r\n"]))

        cond do
          line == "QUIT done" ->
            :gen_tcp.close(socket)

          line == "CAP END" and connection == 2 ->
            Process.sleep(25)
            :gen_tcp.close(socket)

          true ->
            read_loop(socket, test_pid, connection)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp reply("CAP LS 302"), do: [":irc.test CAP * LS :"]
  defp reply("CAP END"), do: [":irc.test 001 nick :Welcome"]
  defp reply(_line), do: []
end

defmodule ReconnectFailureServer do
  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(test_pid) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    Task.start_link(fn -> serve_once(listener, test_pid) end)
    {:ok, %{listener: listener, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp serve_once(listener, test_pid) do
    {:ok, socket} = :gen_tcp.accept(listener)
    read_until_registered(socket, test_pid)
    :gen_tcp.close(listener)
    Process.sleep(25)
    :gen_tcp.close(socket)
  end

  defp read_until_registered(socket, test_pid) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
    line = String.trim(line)
    send(test_pid, {:reconnect_failure_line, line})

    case line do
      "CAP LS 302" ->
        :ok = :gen_tcp.send(socket, ":irc.test CAP * LS :\r\n")
        read_until_registered(socket, test_pid)

      "CAP END" ->
        :ok = :gen_tcp.send(socket, ":irc.test 001 nick :Welcome\r\n")

      _line ->
        read_until_registered(socket, test_pid)
    end
  end
end
