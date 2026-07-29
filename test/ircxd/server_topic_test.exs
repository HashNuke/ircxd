defmodule Ircxd.ServerTopicTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "publishes channel topic changes to channel members" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, alice} = start_client(server, "topic-alice")
    {:ok, bob} = start_client(server, "topic-bob")

    on_exit(fn ->
      for client <- [alice, bob], Process.alive?(client), do: GenServer.stop(client)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#topics")
    assert :ok = Client.join(bob, "#topics")
    wait_for_joins(MapSet.new(["topic-alice", "topic-bob"]))

    assert :ok = Client.topic(alice, "#topics", "A topic")
    wait_for_topics(2)
  end

  test "rejects topic changes from non-members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "topic-owner")
    {:ok, bob} = start_client(server, "topic-outsider")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#topic-membership")
    assert_receive {:ircxd, {:join, %{channel: "#topic-membership"}}}, 2_000

    assert :ok = Client.topic(bob, "#topic-membership", "not allowed")

    assert_receive {:ircxd, {:irc_error, %{code: "442", reason: "You're not on that channel"}}},
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
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_joins(nicks) do
    receive do
      {:ircxd, {:join, %{nick: nick, channel: "#topics"}}} ->
        nicks = MapSet.delete(nicks, nick)
        if MapSet.size(nicks) == 0, do: :ok, else: wait_for_joins(nicks)

      _other ->
        wait_for_joins(nicks)
    after
      2_000 -> flunk("clients did not join")
    end
  end

  defp wait_for_topics(0), do: :ok

  defp wait_for_topics(remaining) do
    receive do
      {:ircxd, {:topic, %{channel: "#topics", topic: "A topic"}}} ->
        wait_for_topics(remaining - 1)

      _other ->
        wait_for_topics(remaining)
    after
      2_000 -> flunk("topic was not published to all members")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
