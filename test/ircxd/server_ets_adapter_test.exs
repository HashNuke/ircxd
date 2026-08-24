defmodule Ircxd.ServerETSAdapterTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}
  alias Ircxd.Server.Adapters.ETS, as: ETSAdapter

  test "projects committed sessions, channels, memberships, topics, and messages" do
    {:ok, server} =
      Server.start_link(
        id: :ets_projection,
        port: 0,
        adapter: {ETSAdapter, history_limit: 10}
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")
    on_exit(fn -> Enum.each([alice, bob], &stop_if_alive/1) end)
    wait_registered(2)

    assert :ok = Client.join(alice, "#adapter")
    assert :ok = Client.join(bob, "#adapter")
    wait_for_joins(2)

    assert :ok = Client.topic(alice, "#adapter", "Adapter-backed channel")
    wait_for_topics(2)
    assert :ok = Client.privmsg(alice, "#adapter", "stored by ETS")

    assert_receive {:ircxd,
                    {:privmsg, %{nick: "alice", target: "#adapter", body: "stored by ETS"}}},
                   2_000

    assert {:ok, users} = Server.query(server, :users)
    assert Enum.map(users, & &1.nick) == ["alice", "bob"]

    assert {:ok, [channel]} = Server.query(server, :channels)
    assert channel.name == "#adapter"
    assert channel.topic == "Adapter-backed channel"
    assert channel.members == ["alice", "bob"]

    assert {:ok, ["#adapter"]} = Server.query(server, {:channels_for, "alice"})

    assert {:ok, [message]} = Server.query(server, {:messages, "#adapter", limit: 10})
    assert message.command == "PRIVMSG"
    assert message.from == "alice"
    assert message.target == "#adapter"
    assert message.body == "stored by ETS"

    assert :ok = Client.part(alice, "#adapter")
    assert :ok = Client.part(bob, "#adapter")
    wait_for_parts(MapSet.new(["alice", "bob"]))

    assert {:ok, [empty_channel]} = Server.query(server, :channels)
    assert empty_channel.name == "#adapter"
    assert empty_channel.members == []
    assert empty_channel.topic == "Adapter-backed channel"
  end

  test "isolates adapter state between server instances" do
    {:ok, first} =
      Server.start_link(id: :first_ets, port: 0, adapter: {ETSAdapter, []})

    {:ok, second} =
      Server.start_link(id: :second_ets, port: 0, adapter: {ETSAdapter, []})

    on_exit(fn -> Enum.each([first, second], &stop_if_alive/1) end)

    {:ok, client} = start_client(first, "first-only")
    on_exit(fn -> stop_if_alive(client) end)
    wait_registered(1)

    assert {:ok, [%{nick: "first-only"}]} = Server.query(first, :users)
    assert {:ok, []} = Server.query(second, :users)
  end

  test "keeps membership projections aligned after a nick change" do
    {:ok, server} = Server.start_link(port: 0, adapter: {ETSAdapter, []})
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "old-nick")
    on_exit(fn -> stop_if_alive(client) end)
    wait_registered(1)

    assert :ok = Client.join(client, "#renamed")
    wait_for_joins(1)
    assert :ok = Client.nick(client, "new-nick")
    assert_receive {:ircxd, {:nick, %{new_nick: "new-nick"}}}, 2_000

    assert {:ok, [channel]} = Server.query(server, :channels)
    assert channel.members == ["new-nick"]
    assert {:ok, ["#renamed"]} = Server.query(server, {:channels_for, "new-nick"})
    assert {:ok, []} = Server.query(server, {:channels_for, "old-nick"})
  end

  test "stores application-managed channel metadata and account permissions" do
    {:ok, server} =
      Server.start_link(id: :managed_ets, port: 0, adapter: {ETSAdapter, []})

    on_exit(fn -> stop_if_alive(server) end)

    assert {:ok, channel} =
             Server.execute(
               server,
               {:put_channel, "#managed",
                %{description: "Managed from the application", topic: "Persistent topic"}}
             )

    assert channel.name == "#managed"

    assert {:ok, :ok} =
             Server.execute(
               server,
               {:put_channel_roles, "#managed", "account-1", [:owner, :moderator]}
             )

    assert {:ok, stored} = Server.query(server, {:channel, "#managed"})
    assert stored.description == "Managed from the application"
    assert stored.topic == "Persistent topic"
    assert stored.acl["account-1"] == MapSet.new([:moderator, :owner])

    assert {:ok, roles} = Server.query(server, {:channel_roles, "#managed", "account-1"})
    assert roles == MapSet.new([:moderator, :owner])
  end

  test "uses stored account roles when authorizing channel access" do
    authenticator = fn username, password, _metadata ->
      if password == "secret", do: {:ok, username}, else: {:error, :invalid_credentials}
    end

    {:ok, server} =
      Server.start_link(
        id: :authorized_ets,
        port: 0,
        allow_insecure_auth: true,
        adapter: {ETSAdapter, authenticate: authenticator}
      )

    on_exit(fn -> stop_if_alive(server) end)

    assert {:ok, :ok} =
             Server.execute(server, {:put_channel_roles, "#managed", "banned-account", [:banned]})

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "banned-user",
        username: "banned-user",
        realname: "Banned user",
        sasl: {:plain, "banned-account", "secret"},
        allow_insecure_auth: true,
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.join(client, "#managed")
    assert_receive {:ircxd, {:irc_error, %{code: "474", reason: "Cannot join channel"}}}, 2_000
    refute_receive {:ircxd, {:join, %{channel: "#managed"}}}, 250
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: "#{nick}-user",
      realname: "#{nick} real name",
      caps: ["no-implicit-names"],
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

  defp wait_for_parts(nicks) do
    receive do
      {:ircxd, {:part, %{nick: nick, channel: "#adapter"}}} ->
        remaining = MapSet.delete(nicks, nick)
        if MapSet.size(remaining) == 0, do: :ok, else: wait_for_parts(remaining)

      _other ->
        wait_for_parts(nicks)
    after
      2_000 -> flunk("clients did not part")
    end
  end

  defp wait_for_topics(0), do: :ok

  defp wait_for_topics(remaining) do
    receive do
      {:ircxd, {:topic, %{channel: "#adapter", topic: "Adapter-backed channel"}}} ->
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
