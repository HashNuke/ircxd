defmodule Ircxd.ClientServerTimeReconnectTest do
  use ExUnit.Case, async: false

  alias Ircxd.Message
  alias Ircxd.ClientServerTimeReconnectTest.ReconnectServer

  test "a stale flush timer cannot flush the next connection's buffer" do
    {:ok, server} = ReconnectServer.start_link(self())

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ReconnectServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["server-time"],
        reconnect: [max_attempts: 1, delay: 0],
        server_time_order: [flush_after: 800],
        notify: self()
      )

    assert_receive {:server_time_reconnect_sent, 1}, 1_000

    assert_receive {:ircxd, {:message, %Message{command: "PRIVMSG", params: ["#room", "first"]}}},
                   1_000

    assert_receive {:ircxd, :disconnected}, 1_000
    assert_receive {:ircxd, {:reconnecting, %{attempt: 1}}}, 1_000
    assert_receive {:server_time_reconnect_sent, 2}, 1_000

    assert_receive {:ircxd,
                    {:message, %Message{command: "PRIVMSG", params: ["#room", "second"]}}},
                   1_000

    refute_receive {:ircxd, {:privmsg, %{body: "second"}}}, 650
    assert_receive {:ircxd, {:privmsg, %{body: "second"}}}, 300
    refute_receive {:ircxd, {:privmsg, %{body: "first"}}}, 50
  end

  defmodule ReconnectServer do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def port(server), do: GenServer.call(server, :port)

    @impl true
    def init(test_pid) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

      {:ok, {_address, port}} = :inet.sockname(listener)
      Task.start_link(fn -> accept_connections(listener, test_pid, 1) end)
      {:ok, %{listener: listener, port: port}}
    end

    @impl true
    def handle_call(:port, _from, state), do: {:reply, state.port, state}

    defp accept_connections(listener, test_pid, connection) when connection <= 2 do
      {:ok, socket} = :gen_tcp.accept(listener)
      negotiate(socket, test_pid, connection)
      accept_connections(listener, test_pid, connection + 1)
    end

    defp accept_connections(_listener, _test_pid, _connection), do: :ok

    defp negotiate(socket, test_pid, connection) do
      {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)

      case String.trim(line) do
        "CAP LS 302" ->
          :ok = :gen_tcp.send(socket, ":irc.test CAP * LS :server-time\r\n")
          negotiate(socket, test_pid, connection)

        "CAP REQ server-time" ->
          :ok = :gen_tcp.send(socket, ":irc.test CAP * ACK :server-time\r\n")
          negotiate(socket, test_pid, connection)

        "CAP END" ->
          send_timed_message(socket, test_pid, connection)

        _line ->
          negotiate(socket, test_pid, connection)
      end
    end

    defp send_timed_message(socket, test_pid, connection) do
      body = if connection == 1, do: "first", else: "second"
      second = if connection == 1, do: "00", else: "01"

      :ok = :gen_tcp.send(socket, ":irc.test 001 nick :Welcome\r\n")

      :ok =
        :gen_tcp.send(
          socket,
          "@time=2026-08-25T10:00:#{second}.000Z :alice!a@example.test PRIVMSG #room :#{body}\r\n"
        )

      send(test_pid, {:server_time_reconnect_sent, connection})

      if connection == 1 do
        Process.sleep(300)
        :gen_tcp.close(socket)
      else
        keep_open(socket)
      end
    end

    defp keep_open(socket) do
      case :gen_tcp.recv(socket, 0, 100) do
        {:error, :timeout} -> keep_open(socket)
        _result -> :ok
      end
    end
  end
end
