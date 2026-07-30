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

  test "binds plain TCP to localhost by default" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert {:ok, {{127, 0, 0, 1}, _port}} = :inet.sockname(:sys.get_state(server).listener)
  end

  test "allows the server bind address to be configured" do
    {:ok, server} = Server.start_link(port: 0, ip: {127, 0, 0, 2})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert {:ok, {{127, 0, 0, 2}, _port}} = :inet.sockname(:sys.get_state(server).listener)
  end

  test "supports multiple servers as children of one supervisor" do
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Server, [id: :first_irc, port: 0, server_name: "first.test"]},
          {Server, [id: :second_irc, port: 0, server_name: "second.test"]}
        ],
        strategy: :one_for_one
      )

    on_exit(fn -> stop_if_alive(supervisor) end)

    children = Supervisor.which_children(supervisor) |> Enum.sort_by(&elem(&1, 0))

    [{:first_irc, first, :worker, [Server]}, {:second_irc, second, :worker, [Server]}] = children

    assert Server.port(first) != Server.port(second)
  end

  defp stop_if_alive(pid) do
    Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
