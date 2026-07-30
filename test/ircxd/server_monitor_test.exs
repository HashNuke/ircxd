defmodule Ircxd.ServerMonitorTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "tracks monitored nicknames and publishes online/offline state" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.monitor_add(alice, ["bob", "missing"])

    assert_receive {:ircxd, {:monitor, %{type: :online, targets: ["bob!user@ircxd.local"]}}},
                   2_000

    assert_receive {:ircxd, {:monitor, %{type: :offline, targets: ["missing"]}}}, 2_000

    assert :ok = Client.monitor_list(alice)
    assert_receive {:ircxd, {:monitor, %{type: :list, targets: targets}}}, 2_000
    assert Enum.sort(targets) == ["bob", "missing"]
    assert_receive {:ircxd, {:monitor, %{type: :list_end}}}, 2_000

    assert :ok = Client.monitor_clear(alice)
    assert :ok = Client.monitor_list(alice)
    assert_receive {:ircxd, {:monitor, %{type: :list, targets: []}}}, 2_000
    assert_receive {:ircxd, {:monitor, %{type: :list_end}}}, 2_000
    assert :ok = GenServer.stop(bob)
    refute_receive {:ircxd, {:monitor, %{type: :offline, targets: ["bob"]}}}, 250
  end

  test "notifies a monitor when a watched nickname connects and disconnects" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    on_exit(fn -> stop_if_alive(alice) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.monitor_add(alice, "bob")
    assert_receive {:ircxd, {:monitor, %{type: :offline, targets: ["bob"]}}}, 2_000

    {:ok, bob} = start_client(server, "bob")
    assert_receive {:ircxd, :registered}, 2_000

    assert_receive {:ircxd, {:monitor, %{type: :online, targets: ["bob!user@ircxd.local"]}}},
                   2_000

    assert :ok = GenServer.stop(bob)
    assert_receive {:ircxd, {:monitor, %{type: :offline, targets: ["bob"]}}}, 2_000
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
