defmodule Ircxd.ServerStatsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns standalone server uptime for STATS u" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "stats-client",
        username: "stats-client",
        realname: "Ircxd stats client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.stats(client, "u")
    assert_receive {:ircxd, {:stats_uptime, %{text: text}}}, 2_000
    assert text =~ "Server up"
    assert_receive {:ircxd, {:stats_end, %{query: "u"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
