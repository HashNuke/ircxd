defmodule Ircxd.ServerNickChangeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "broadcasts registered nickname changes to channel members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#nick-change")
    assert_receive {:ircxd, {:join, %{channel: "#nick-change", nick: "alice"}}}, 2_000
    assert :ok = Client.join(bob, "#nick-change")
    assert_receive {:ircxd, {:join, %{channel: "#nick-change", nick: "bob"}}}, 2_000

    assert :ok = Client.nick(alice, "alice-new")

    assert_receive {:ircxd, {:nick, %{old_nick: "alice", new_nick: "alice-new"}}}, 2_000
    assert_receive {:ircxd, {:nick, %{old_nick: "alice", new_nick: "alice-new"}}}, 2_000
    assert :sys.get_state(alice).current_nick == "alice-new"

    assert :ok = Client.privmsg(bob, "alice-new", "still reachable")
    assert_receive {:ircxd, {:privmsg, %{nick: "bob", target: "alice-new"}}}, 2_000
  end

  test "rejects a registered nickname change that is already in use" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice-collision")
    {:ok, bob} = start_client(server, "bob-collision")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.nick(alice, "bob-collision")

    assert_receive {:ircxd, {:nick_in_use, %{attempted: "bob-collision"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
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

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
