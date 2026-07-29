defmodule Ircxd.ServerOperatorModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "+o grants and -o revokes channel-operator authority" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")
    {:ok, carol} = start_client(server, "carol")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
      stop_if_alive(carol)
    end)

    wait_registered(3)

    assert :ok = Client.join(alice, "#ops")
    assert_receive {:ircxd, {:join, %{channel: "#ops", nick: "alice"}}}, 2_000
    assert :ok = Client.join(bob, "#ops")
    assert_receive {:ircxd, {:join, %{channel: "#ops", nick: "bob"}}}, 2_000
    assert :ok = Client.join(carol, "#ops")
    assert_receive {:ircxd, {:join, %{channel: "#ops", nick: "carol"}}}, 2_000

    assert :ok = Client.mode(alice, "#ops", "+o", ["bob"])

    assert_receive {:ircxd, {:mode, %{target: "#ops", modes: "+o", params: ["bob"]}}},
                   2_000

    assert :ok = Client.kick(bob, "#ops", "carol", "delegated")

    assert_receive {:ircxd,
                    {:kick, %{channel: "#ops", target_nick: "carol", reason: "delegated"}}},
                   2_000

    assert :ok = Client.join(carol, "#ops")
    assert_receive {:ircxd, {:join, %{channel: "#ops", nick: "carol"}}}, 2_000

    assert :ok = Client.mode(alice, "#ops", "-o", ["bob"])

    assert_receive {:ircxd, {:mode, %{target: "#ops", modes: "-o", params: ["bob"]}}},
                   2_000

    assert :ok = Client.kick(bob, "#ops", "carol", "should fail")
    assert_receive {:ircxd, {:irc_error, %{code: "482"}}}, 2_000
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
