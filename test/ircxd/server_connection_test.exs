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

  test "accepts client PONG replies without reporting an unknown command" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} = start_client(server, "pong-client")
    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    wait_registered()

    assert :ok = Client.raw(client, "PONG", ["server-check"])
    refute_receive {:ircxd, {:irc_error, %{code: "421", target: "PONG"}}}, 500
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick}",
      notify: self()
    )
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
