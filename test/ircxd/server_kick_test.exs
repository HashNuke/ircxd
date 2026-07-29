defmodule Ircxd.ServerKickTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "removes a kicked member and publishes KICK to channel members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#kick")
    assert :ok = Client.join(bob, "#kick")
    wait_for_joins(MapSet.new(["alice", "bob"]))

    assert :ok = Client.kick(alice, "#kick", "bob", "cleanup")

    assert_receive {:ircxd, {:kick, %{channel: "#kick", target_nick: "bob", reason: "cleanup"}}},
                   2_000

    assert_receive {:ircxd, {:kick, %{channel: "#kick", target_nick: "bob", reason: "cleanup"}}},
                   2_000

    assert :ok = Client.names(alice, "#kick")
    assert_receive {:ircxd, {:names, %{channel: "#kick", names: names}}}, 2_000
    assert Enum.map(names, & &1.nick) == ["alice"]
    assert_receive {:ircxd, {:names_end, %{channel: "#kick"}}}, 2_000

    assert :ok = Client.privmsg(bob, "#kick", "still here?")
    assert_receive {:ircxd, {:irc_error, %{code: "404", reason: "Cannot send to channel"}}}, 2_000
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

  defp wait_for_joins(nicks) do
    receive do
      {:ircxd, {:join, %{nick: nick, channel: "#kick"}}} ->
        nicks = MapSet.delete(nicks, nick)
        if MapSet.size(nicks) == 0, do: :ok, else: wait_for_joins(nicks)

      _other ->
        wait_for_joins(nicks)
    after
      2_000 -> flunk("clients did not join")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
