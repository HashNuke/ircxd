defmodule Ircxd.ServerLinksTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "reports the standalone server in LINKS results" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "links-client",
        username: "links-client",
        realname: "Ircxd links client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.links(client)

    assert_receive {:ircxd,
                    {:links,
                     %{mask: "*", server: "ircxd.test", hopcount: "0", info: "Ircxd server"}}},
                   2_000

    assert_receive {:ircxd, {:links_end, %{mask: "*"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
