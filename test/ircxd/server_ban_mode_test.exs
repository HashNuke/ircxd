defmodule Ircxd.ServerBanModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "+b rejects a matching nick and -b permits it again" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "ban-alice")
    {:ok, bob} = start_client(server, "ban-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#banned")
    assert_receive {:ircxd, {:join, %{channel: "#banned", nick: "ban-alice"}}}, 2_000

    assert :ok = Client.mode(alice, "#banned", "+b", ["ban-bob"])

    assert_receive {:ircxd, {:mode, %{target: "#banned", modes: "+b", params: ["ban-bob"]}}},
                   2_000

    assert :ok = Client.mode(alice, "#banned", "+b")
    assert_receive {:ircxd, {:ban_list, %{channel: "#banned", mask: "ban-bob"}}}, 2_000
    assert_receive {:ircxd, {:ban_list_end, %{channel: "#banned"}}}, 2_000

    assert :ok = Client.join(bob, "#banned")
    assert_receive {:ircxd, {:irc_error, %{code: "474", target: "#banned"}}}, 2_000

    assert :ok = Client.mode(alice, "#banned", "-b", ["ban-bob"])

    assert_receive {:ircxd, {:mode, %{target: "#banned", modes: "-b", params: ["ban-bob"]}}},
                   2_000

    assert :ok = Client.join(bob, "#banned")
    assert_receive {:ircxd, {:join, %{channel: "#banned", nick: "ban-bob"}}}, 2_000
    assert_receive {:ircxd, {:join, %{channel: "#banned", nick: "ban-bob"}}}, 2_000
  end

  test "wildcard nick masks reject matching users" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "wild-alice")
    {:ok, bob} = start_client(server, "wild-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#wild-bans")
    assert_receive {:ircxd, {:join, %{channel: "#wild-bans"}}}, 2_000
    assert :ok = Client.mode(alice, "#wild-bans", "+b", ["wild-*"])
    assert_receive {:ircxd, {:mode, %{target: "#wild-bans", modes: "+b"}}}, 2_000

    assert :ok = Client.join(bob, "#wild-bans")
    assert_receive {:ircxd, {:irc_error, %{code: "474", target: "#wild-bans"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
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

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
