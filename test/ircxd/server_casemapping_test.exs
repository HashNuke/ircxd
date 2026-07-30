defmodule Ircxd.ServerCasemappingTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "rejects nickname collisions under the advertised casemapping" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        isupport: ["CHANTYPES=#&", "NICKLEN=30", "CASEMAPPING=rfc1459"]
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, first} = start_client(server, "Nick[")
    on_exit(fn -> stop_if_alive(first) end)
    assert_receive {:ircxd, :registered}, 2_000

    {:ok, socket} =
      :gen_tcp.connect(
        ~c"127.0.0.1",
        Server.port(server),
        [:binary, packet: :line, active: false],
        2_000
      )

    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, "NICK nick{\r\nUSER collision 0 * :collision\r\n")

    assert {:ok, line} = receive_until(socket, "433 ", 2_000)
    assert line =~ "nick{"
  end

  test "routes nick and channel targets case-insensitively without splitting channels" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "Alice")
    {:ok, bob} = start_client(server, "Bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)

    assert :ok = Client.privmsg(alice, "bOB", "casefolded direct message")

    assert_receive {:ircxd,
                    {:privmsg, %{nick: "Alice", target: "Bob", body: "casefolded direct message"}}},
                   2_000

    assert :ok = Client.join(alice, "#Ops")
    assert_receive {:ircxd, {:join, %{channel: "#Ops", nick: "Alice"}}}, 2_000

    assert :ok = Client.join(bob, "#oPS")
    assert_receive {:ircxd, {:join, %{channel: "#Ops", nick: "Bob"}}}, 2_000
    assert_receive {:ircxd, {:join, %{channel: "#Ops", nick: "Bob"}}}, 2_000

    assert :ok = Client.mode(alice, "#oPS", "+v", ["bOB"])

    assert_receive {:ircxd, {:mode, %{target: "#Ops", modes: "+v", params: ["Bob"]}}},
                   2_000

    state = :sys.get_state(server)
    assert map_size(state.channels) == 1
    assert state.channel_index["#ops"] == "#Ops"
  end

  test "applies casemapping to bans and MONITOR targets" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "Alice")
    {:ok, bob} = start_client(server, "Bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.monitor_add(alice, "bOB")

    assert_receive {:ircxd, {:monitor, %{type: :online, targets: ["Bob!user@ircxd.local"]}}},
                   2_000

    assert :ok = Client.join(alice, "#Secure")
    assert_receive {:ircxd, {:join, %{channel: "#Secure", nick: "Alice"}}}, 2_000
    assert :ok = Client.mode(alice, "#sECURE", "+b", ["bOB!*@*"])
    assert_receive {:ircxd, {:mode, %{target: "#Secure", modes: "+b"}}}, 2_000

    assert :ok = Client.join(bob, "#SECURE")
    assert_receive {:ircxd, {:irc_error, %{code: "474", target: "#Secure"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: nick,
      caps: ["no-implicit-names"],
      notify: self()
    )
  end

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      _other -> wait_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
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
