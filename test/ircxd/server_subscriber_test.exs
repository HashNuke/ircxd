defmodule Ircxd.ServerSubscriberTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  defmodule Recorder do
    @behaviour Ircxd.Server.Subscriber

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_publish(message, metadata, test_pid) do
      send(test_pid, {:published, message, metadata})
      {:ok, test_pid}
    end
  end

  defmodule SlowSubscriber do
    @behaviour Ircxd.Server.Subscriber

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_publish(_message, _metadata, test_pid) do
      send(test_pid, :slow_subscriber_started)
      Process.sleep(500)
      {:ok, test_pid}
    end
  end

  defmodule FailingSubscriber do
    @behaviour Ircxd.Server.Subscriber

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_publish(_message, _metadata, test_pid) do
      send(test_pid, :failing_subscriber_called)
      raise "subscriber failure"
    end
  end

  defmodule RejectingSubscriber do
    @behaviour Ircxd.Server.Subscriber

    @impl true
    def init(:reject), do: {:error, :subscriber_unavailable}

    @impl true
    def handle_publish(_message, _metadata, state), do: {:ok, state}
  end

  test "receives every published server message with connection metadata" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "ircxd.test",
        subscriber: {Recorder, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "subscriber-test",
        username: "user",
        realname: "Ircxd test client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:published, %Message{command: "CAP"}, %{connection: _}}, 2_000

    assert_receive {:published, %Message{command: "001", params: ["subscriber-test", _]},
                    metadata},
                   2_000

    assert metadata.server == "ircxd.test"
    assert metadata.nick == "subscriber-test"
  end

  test "a slow subscriber does not block server command routing" do
    {:ok, server} = Server.start_link(port: 0, subscriber: {SlowSubscriber, self()})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "slow-subscriber",
        username: "user",
        realname: "Ircxd slow subscriber client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive :slow_subscriber_started, 2_000
    :ok = Client.join(client, "#responsive")
    assert_receive {:ircxd, {:message, %Message{command: "JOIN", params: ["#responsive"]}}}, 250
  end

  test "a subscriber exception does not take down the server" do
    {:ok, server} = Server.start_link(port: 0, subscriber: {FailingSubscriber, self()})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "failing-subscriber",
        username: "user",
        realname: "Ircxd failing subscriber client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive :failing_subscriber_called, 2_000
    assert_receive {:ircxd, :registered}, 2_000
    assert Process.alive?(server)
  end

  test "closes the listener when subscriber initialization fails" do
    {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(probe)
    :ok = :gen_tcp.close(probe)

    previous_trap_exit = Process.flag(:trap_exit, true)

    result = Server.start_link(port: port, subscriber: {RejectingSubscriber, :reject})

    Process.flag(:trap_exit, previous_trap_exit)
    assert {:error, {:subscriber_init_failed, :subscriber_unavailable}} = result

    assert {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    :ok = :gen_tcp.close(socket)
  end
end
