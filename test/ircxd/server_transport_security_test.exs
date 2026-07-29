defmodule Ircxd.ServerTransportSecurityTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  test "uses active-once flow control and a socket-level IRCv3 line bound" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "flow-control")
    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    [{connection, _client_state}] = :sys.get_state(server).connections |> Map.to_list()
    socket = :sys.get_state(connection).socket

    assert {:ok,
            [
              active: active,
              packet_size: packet_size
            ]} = :inet.getopts(socket, [:active, :packet_size])

    assert active in [:once, false]
    assert packet_size == Message.max_received_wire_bytes()
  end

  test "disconnects a peer that sends an oversized unterminated line" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)
    {:ok, socket} = connect_raw(server)

    payload = String.duplicate("x", Message.max_received_wire_bytes() + 1)
    assert :ok = :gen_tcp.send(socket, payload)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  test "disconnects clients that exceed the configured command rate" do
    {:ok, server} = Server.start_link(port: 0, command_rate_limit: 5)
    on_exit(fn -> stop_if_alive(server) end)
    {:ok, socket} = connect_raw(server)

    assert :ok =
             :gen_tcp.send(
               socket,
               "NICK rate-limited\r\nUSER rate-limited 0 * :rate-limited\r\n"
             )

    assert {:ok, _welcome} = receive_until(socket, "001 ", 2_000)

    assert :ok =
             :gen_tcp.send(
               socket,
               for(index <- 1..10, do: "PING :#{index}\r\n")
             )

    assert {:ok, error} = receive_until(socket, "ERROR :Excess flood", 2_000)
    assert error =~ "Excess flood"
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  test "enforces the configured global connection limit" do
    {:ok, server} = Server.start_link(port: 0, max_connections: 1)
    on_exit(fn -> stop_if_alive(server) end)
    {:ok, first} = connect_raw(server)
    on_exit(fn -> :gen_tcp.close(first) end)

    wait_for_connection_count(server, 1)
    {:ok, second} = connect_raw(server)
    assert {:error, :closed} = :gen_tcp.recv(second, 0, 2_000)
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: nick,
      notify: self()
    )
  end

  defp connect_raw(server) do
    :gen_tcp.connect(
      ~c"127.0.0.1",
      Server.port(server),
      [:binary, packet: :line, active: false],
      2_000
    )
  end

  defp wait_for_connection_count(server, expected, attempts \\ 50)
  defp wait_for_connection_count(_server, _expected, 0), do: flunk("connection was not accepted")

  defp wait_for_connection_count(server, expected, attempts) do
    if map_size(:sys.get_state(server).connections) == expected do
      :ok
    else
      Process.sleep(10)
      wait_for_connection_count(server, expected, attempts - 1)
    end
  end

  defp receive_until(socket, pattern, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_until(socket, pattern, deadline)
  end

  defp do_receive_until(socket, pattern, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.recv(socket, 0, remaining) do
      {:ok, line} ->
        if String.contains?(line, pattern),
          do: {:ok, line},
          else: do_receive_until(socket, pattern, deadline)

      error ->
        error
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
