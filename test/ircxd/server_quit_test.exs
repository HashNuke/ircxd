defmodule Ircxd.ServerQuitTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "broadcasts QUIT and removes the client from channel state" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, alice} = start_client(server, "quit-alice")
    {:ok, bob} = start_client(server, "quit-bob")

    on_exit(fn ->
      for client <- [alice, bob], Process.alive?(client), do: GenServer.stop(client)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#quit")
    assert :ok = Client.join(bob, "#quit")
    wait_for_joins(2)

    assert :ok = Client.quit(alice, "gone")

    assert_receive {:ircxd, {:quit, %{nick: "quit-alice", reason: "gone"}}}, 2_000

    assert :ok = Client.names(bob, "#quit")
    assert_receive {:ircxd, {:names, %{channel: "#quit", names: names}}}, 2_000
    refute Enum.any?(names, &(&1.nick == "quit-alice"))
    assert Enum.any?(names, &(&1.nick == "quit-bob"))
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "#{nick} test client",
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

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, _payload}} -> wait_for_joins(remaining - 1)
      _other -> wait_for_joins(remaining)
    after
      2_000 -> flunk("clients did not join")
    end
  end
end
