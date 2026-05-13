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
