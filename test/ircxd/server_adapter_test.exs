defmodule Ircxd.ServerAdapterTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  defmodule Adapter do
    @behaviour Ircxd.Server.Adapter

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_publish(%Message{command: "001"} = message, metadata, test_pid) do
      send(test_pid, {:published, message, metadata})
      {:ok, test_pid}
    end

    def handle_publish(_message, _metadata, test_pid), do: {:ok, test_pid}

    @impl true
    def authenticate(username, password, metadata, test_pid) do
      send(test_pid, {:authenticated, username, password, metadata})
      {:ok, "account-123", test_pid}
    end
  end

  defmodule PolicyAdapter do
    @behaviour Ircxd.Server.Adapter

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def authorize({:join, "#blocked"}, context, test_pid) do
      send(test_pid, {:authorization_checked, context})
      {:error, :forbidden, test_pid}
    end

    def authorize({:set_topic, "#readonly"}, context, test_pid) do
      send(test_pid, {:authorization_checked, context})
      {:error, :read_only, test_pid}
    end

    def authorize(_action, _context, test_pid), do: {:ok, test_pid}
  end

  defmodule CommandAdapter do
    @behaviour Ircxd.Server.Adapter

    alias Ircxd.Message

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_command(%Message{command: "GETDESC", params: [channel]}, context, test_pid) do
      send(test_pid, {:custom_command, channel, context.actor.nick})

      {:reply, [%Message{command: "NOTICE", params: [context.actor.nick, "#{channel}: From DB"]}],
       test_pid}
    end

    def handle_command(_message, _context, test_pid), do: {:unhandled, test_pid}
  end

  test "one adapter owns message publication and authentication" do
    {:ok, server} =
      Server.start_link(port: 0, allow_insecure_auth: true, adapter: {Adapter, self()})

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "adapter-test",
        username: "adapter-test",
        realname: "Adapter test",
        sasl: {:plain, "adapter-test", "secret"},
        allow_insecure_auth: true,
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:authenticated, "adapter-test", "secret", %{mechanism: :plain}}, 2_000
    assert_receive {:published, %Message{command: "001"}, %{nick: "adapter-test"}}, 2_000
    assert_receive {:ircxd, {:logged_in, %{account: "account-123"}}}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
  end

  test "adapter policy can reject a state-changing IRC command" do
    {:ok, server} = Server.start_link(port: 0, adapter: {PolicyAdapter, self()})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "policy-test",
        username: "policy-test",
        realname: "Policy test",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.join(client, "#blocked")

    assert_receive {:authorization_checked,
                    %{action: {:join, "#blocked"}, actor: %{nick: "policy-test"}}},
                   2_000

    assert_receive {:ircxd, {:irc_error, %{code: "474", reason: "Cannot join channel"}}},
                   2_000

    refute_receive {:ircxd, {:join, %{channel: "#blocked"}}}, 250
  end

  test "adapter can answer application-specific commands" do
    {:ok, server} = Server.start_link(port: 0, adapter: {CommandAdapter, self()})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "command-test",
        username: "command-test",
        realname: "Command test",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "GETDESC", ["#managed"])
    assert_receive {:custom_command, "#managed", "command-test"}, 2_000

    assert_receive {:ircxd,
                    {:notice,
                     %{nick: "ircxd.local", target: "command-test", body: "#managed: From DB"}}},
                   2_000

    refute_receive {:ircxd, {:irc_error, %{code: "421"}}}, 250
  end

  test "adapter policy can reject a channel topic update" do
    {:ok, server} = Server.start_link(port: 0, adapter: {PolicyAdapter, self()})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "topic-policy",
        username: "topic-policy",
        realname: "Topic policy",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.join(client, "#readonly")
    assert_receive {:ircxd, {:join, %{channel: "#readonly"}}}, 2_000

    assert :ok = Client.topic(client, "#readonly", "should not persist")

    assert_receive {:authorization_checked,
                    %{action: {:set_topic, "#readonly"}, actor: %{nick: "topic-policy"}}},
                   2_000

    assert_receive {:ircxd, {:irc_error, %{code: "482"}}}, 2_000
    refute_receive {:ircxd, {:topic, %{topic: "should not persist"}}}, 250
  end
end
