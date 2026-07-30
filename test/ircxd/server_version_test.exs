defmodule Ircxd.ServerVersionTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns VERSION information for the configured server" do
    {:ok, server} = Server.start_link(port: 0, server_name: "version.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "version-client",
        username: "user",
        realname: "Ircxd VERSION client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.version(client)

    assert_receive {:ircxd,
                    {:version,
                     %{version: "Ircxd.Server", server: "version.test", comments: comments}}},
                   2_000

    assert comments == "Ircxd server"
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
