defmodule Ircxd.ServerImplicitNamesTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "sends implicit NAMES after JOIN by default" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)
    {:ok, client} = start_client(server, "implicit-names", [])
    on_exit(fn -> stop_if_alive(client) end)
    wait_for_registration()

    assert :ok = Client.join(client, "#implicit")
    assert_receive {:ircxd, {:join, %{channel: "#implicit"}}}, 2_000
    assert_receive {:ircxd, {:names, %{channel: "#implicit"}}}, 2_000
    assert_receive {:ircxd, {:names_end, %{channel: "#implicit"}}}, 2_000
  end

  test "suppresses implicit NAMES for no-implicit-names clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)
    {:ok, client} = start_client(server, "no-implicit", ["no-implicit-names"])
    on_exit(fn -> stop_if_alive(client) end)
    wait_for_registration()

    assert :ok = Client.join(client, "#no-implicit")
    assert_receive {:ircxd, {:join, %{channel: "#no-implicit"}}}, 2_000
    refute_receive {:ircxd, {:names, %{channel: "#no-implicit"}}}, 300
    refute_receive {:ircxd, {:names_end, %{channel: "#no-implicit"}}}, 300
  end

  defp start_client(server, nick, caps) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      notify: self()
    )
  end

  defp wait_for_registration do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_for_registration()
    after
      2_000 -> flunk("client did not register")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
