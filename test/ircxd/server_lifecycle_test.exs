defmodule Ircxd.ServerLifecycleTest do
  use ExUnit.Case, async: false

  alias Ircxd.Server

  test "exposes a supervision-tree child" do
    assert %{id: Server, start: {Server, :start_link, [[port: 0]]}} = Server.child_spec(port: 0)
  end

  test "supports multiple isolated server instances" do
    {:ok, first} = Server.start_link(port: 0, server_name: "first.test")
    {:ok, second} = Server.start_link(port: 0, server_name: "second.test")

    on_exit(fn ->
      for server <- [first, second], Process.alive?(server), do: GenServer.stop(server)
    end)

    assert Server.port(first) != Server.port(second)
  end
end
