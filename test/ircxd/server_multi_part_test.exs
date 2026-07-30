defmodule Ircxd.ServerMultiPartTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "parts comma-separated channel targets with the same reason" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "multi-part",
        username: "user",
        realname: "Ircxd multi-part client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.raw(client, "JOIN", ["#one,#two"])
    assert_receive {:ircxd, {:join, %{channel: "#one"}}}, 2_000
    assert_receive {:ircxd, {:join, %{channel: "#two"}}}, 2_000

    assert :ok = Client.raw(client, "PART", ["#one,#two", "leaving"])
    assert_receive {:ircxd, {:part, %{channel: "#one", reason: "leaving"}}}, 2_000
    assert_receive {:ircxd, {:part, %{channel: "#two", reason: "leaving"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
