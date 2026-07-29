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
end
