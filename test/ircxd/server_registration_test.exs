defmodule Ircxd.ServerRegistrationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "accepts a registration from Ircxd.Client" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "registration",
        username: "user",
        realname: "Ircxd test client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:ircxd, :registered}, 2_000
  end
end
