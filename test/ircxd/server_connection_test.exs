defmodule Ircxd.ServerConnectionTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "responds to client PING through the public client API" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "ping-client",
        username: "ping-client",
        realname: "Ircxd ping client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    wait_registered()

    assert :ok = Client.raw(client, "PING", ["server-check"])
    assert_receive {:ircxd, {:pong, %{token: "server-check"}}}, 2_000
  end

  defp wait_registered do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_registered()
    after
      2_000 -> flunk("client did not register")
    end
  end
end
