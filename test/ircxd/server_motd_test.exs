defmodule Ircxd.ServerMotdTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "serves configured MOTD lines with standard numerics" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        motd: ["Welcome to Ircxd", "Please be kind to other clients"]
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "motd-client",
        username: "user",
        realname: "Ircxd MOTD client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.motd(client)
    assert_receive {:ircxd, {:motd_start, %{text: "- ircxd.local Message of the day -"}}}, 2_000
    assert_receive {:ircxd, {:motd, %{text: "Welcome to Ircxd"}}}, 2_000
    assert_receive {:ircxd, {:motd, %{text: "Please be kind to other clients"}}}, 2_000
    assert_receive {:ircxd, {:motd_end, %{text: "End of /MOTD command"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
