defmodule Ircxd.ServerListFilterTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "supports wildcard channel masks in LIST" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "list-filter-client",
        username: "list-filter-client",
        realname: "Ircxd list filter client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.join(client, "#elixir")
    assert_receive {:ircxd, {:join, %{channel: "#elixir"}}}, 2_000
    assert :ok = Client.join(client, "#elm")
    assert_receive {:ircxd, {:join, %{channel: "#elm"}}}, 2_000
    assert :ok = Client.join(client, "#rust")
    assert_receive {:ircxd, {:join, %{channel: "#rust"}}}, 2_000

    assert :ok = Client.list(client, "#el*")
    assert_receive {:ircxd, {:list_entry, %{channel: "#elixir"}}}, 2_000
    assert_receive {:ircxd, {:list_entry, %{channel: "#elm"}}}, 2_000
    refute_receive {:ircxd, {:list_entry, %{channel: "#rust"}}}, 250
    assert_receive {:ircxd, {:list_end, _}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
