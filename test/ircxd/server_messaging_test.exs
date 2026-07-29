defmodule Ircxd.ServerMessagingTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "fans PRIVMSG to every client joined to the channel" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      for client <- [alice, bob], Process.alive?(client), do: GenServer.stop(client)
    end)

    wait_registered(2)

    assert :ok = Client.join(alice, "#elixir")
    assert :ok = Client.join(bob, "#elixir")
    wait_for_joins(MapSet.new(["alice", "bob"]))

    assert :ok = Client.privmsg(alice, "#elixir", "hello from alice")

    assert_receive {:ircxd,
                    {:privmsg, %{nick: "alice", target: "#elixir", body: "hello from alice"}}},
                   2_000

    assert_receive {:ircxd,
                    {:privmsg, %{nick: "alice", target: "#elixir", body: "hello from alice"}}},
                   2_000
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
      2_000 -> flunk("client did not register")
    end
  end

  defp wait_for_joins(nicks) do
    receive do
      {:ircxd, {:join, %{nick: nick, channel: "#elixir"}}} ->
        nicks = MapSet.delete(nicks, nick)
        if MapSet.size(nicks) == 0, do: :ok, else: wait_for_joins(nicks)

      _other ->
        wait_for_joins(nicks)
    after
      2_000 -> flunk("clients did not join")
    end
  end
end
