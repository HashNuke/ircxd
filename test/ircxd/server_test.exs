defmodule Ircxd.ServerTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "exposes a supervision-tree child and accepts a client registration" do
    assert %{id: Server, start: {Server, :start_link, [[port: 0]]}} = Server.child_spec(port: 0)

    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} = start_client(server, "registration")
    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:ircxd, :registered}, 2_000
  end

  test "supports multiple isolated server instances" do
    {:ok, first} = Server.start_link(port: 0, server_name: "first.test")
    {:ok, second} = Server.start_link(port: 0, server_name: "second.test")

    on_exit(fn ->
      for server <- [first, second], Process.alive?(server), do: GenServer.stop(server)
    end)

    assert Server.port(first) != Server.port(second)

    {:ok, first_client} = start_client(first, "first")
    {:ok, second_client} = start_client(second, "second")

    on_exit(fn ->
      for client <- [first_client, second_client],
          Process.alive?(client),
          do: GenServer.stop(client)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
  end

  defp start_client(server, suffix) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: "nick#{suffix}",
      username: "user#{suffix}",
      realname: "Ircxd test client",
      notify: self()
    )
  end
end
