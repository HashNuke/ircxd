defmodule Ircxd.ServerUserQueriesTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "answers ISON and USERHOST for registered users" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)

    assert :ok = Client.ison(alice, ["alice", "bob", "missing"])
    assert_receive {:ircxd, {:ison, %{nicks: nicks}}}, 2_000
    assert Enum.sort(nicks) == ["alice", "bob"]

    assert :ok = Client.userhost(alice, ["alice", "bob", "missing"])
    assert_receive {:ircxd, {:userhost, %{entries: entries}}}, 2_000
    assert Enum.map(entries, & &1.nick) |> Enum.sort() == ["alice", "bob"]
    assert Enum.all?(entries, &(&1.username in ["alice", "bob"]))
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      notify: self()
    )
  end

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      _other -> wait_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
