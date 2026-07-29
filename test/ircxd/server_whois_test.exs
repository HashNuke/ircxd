defmodule Ircxd.ServerWhoisTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns identity and server details from WHOIS" do
    {:ok, server} = Server.start_link(port: 0, server_name: "whois.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "whois-client",
        username: "whois-user",
        realname: "Ircxd WHOIS client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.whois(client, "whois-client")

    assert_receive {:ircxd,
                    {:whois_user,
                     %{
                       nick: "whois-client",
                       username: "whois-user",
                       realname: "Ircxd WHOIS client"
                     }}},
                   2_000

    assert_receive {:ircxd,
                    {:whois_server,
                     %{nick: "whois-client", server: "whois.test", info: "Ircxd server"}}},
                   2_000

    assert_receive {:ircxd, {:whois_end, %{nick: "whois-client"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
