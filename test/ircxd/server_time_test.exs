defmodule Ircxd.ServerTimeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns the configured server name and UTC time" do
    {:ok, server} = Server.start_link(port: 0, server_name: "time.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "time-client",
        username: "user",
        realname: "Ircxd TIME client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.time(client)
    assert_receive {:ircxd, {:time, %{server: "time.test", time: time}}}, 2_000
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(time)
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
