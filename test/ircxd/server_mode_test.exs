defmodule Ircxd.ServerModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "answers channel and user MODE queries" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "mode-client",
        username: "user",
        realname: "Ircxd mode client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.join(client, "#modes")
    assert_receive {:ircxd, {:join, %{channel: "#modes"}}}, 2_000

    assert :ok = Client.channel_modes(client, "#modes")
    assert_receive {:ircxd, {:channel_mode, %{channel: "#modes", modes: "+"}}}, 2_000

    assert :ok = Client.user_modes(client, "mode-client")
    assert_receive {:ircxd, {:user_mode, %{modes: "+"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
