defmodule Ircxd.ServerPrivateModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "private channels are hidden from LIST and use the private NAMES symbol" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "private-alice")
    {:ok, bob} = start_client(server, "private-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#private")
    assert_receive {:ircxd, {:join, %{channel: "#private"}}}, 2_000
    assert :ok = Client.mode(alice, "#private", "+p")
    assert_receive {:ircxd, {:mode, %{target: "#private", modes: "+p"}}}, 2_000

    assert :ok = Client.mode_query(alice, "#private")
    assert_receive {:ircxd, {:channel_mode, %{channel: "#private", modes: "+np"}}}, 2_000

    assert :ok = Client.list(bob)
    assert_receive {:ircxd, {:list_start, _}}, 2_000
    refute_receive {:ircxd, {:list_entry, %{channel: "#private"}}}, 300
    assert_receive {:ircxd, {:list_end, _}}, 2_000

    assert :ok = Client.names(bob, "#private")
    assert_receive {:ircxd, {:names, %{channel: "#private", symbol: "*"}}}, 2_000
    assert_receive {:ircxd, {:names_end, %{channel: "#private"}}}, 2_000
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
