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
end
