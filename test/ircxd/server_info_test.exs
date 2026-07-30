defmodule Ircxd.ServerInfoTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns configured INFO lines and an end marker" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        info: ["Ircxd.Server", "Embedded IRC for the host application"]
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "info-client",
        username: "info-client",
        realname: "Ircxd info client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.info(client)
    assert_receive {:ircxd, {:info, %{text: "Ircxd.Server"}}}, 2_000

    assert_receive {:ircxd, {:info, %{text: "Embedded IRC for the host application"}}},
                   2_000

    assert_receive {:ircxd, {:info_end, _}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
