defmodule Ircxd.ServerIsolationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  defmodule Recorder do
    @behaviour Ircxd.Server.Adapter

    @impl true
    def init({test_pid, label}), do: {:ok, {test_pid, label}}

    @impl true
    def handle_publish(%Message{} = message, _metadata, {test_pid, label}) do
      send(test_pid, {label, message})
      {:ok, {test_pid, label}}
    end
  end

  test "keeps client traffic and subscribers isolated between server instances" do
    {:ok, first} =
      Server.start_link(
        port: 0,
        server_name: "first.test",
        adapter: {Recorder, {self(), :first}}
      )

    {:ok, second} =
      Server.start_link(
        port: 0,
        server_name: "second.test",
        adapter: {Recorder, {self(), :second}}
      )

    on_exit(fn ->
      for server <- [first, second], Process.alive?(server), do: GenServer.stop(server)
    end)

    {:ok, first_client} = start_client(first, "first-client")
    {:ok, second_client} = start_client(second, "second-client")

    on_exit(fn ->
      for client <- [first_client, second_client],
          Process.alive?(client),
          do: GenServer.stop(client)
    end)

    wait_registered(2)
    assert :ok = Client.join(first_client, "#same")
    assert :ok = Client.join(second_client, "#same")
    wait_for_joins(2)

    assert :ok = Client.privmsg(first_client, "#same", "first only")

    assert_receive {:first, %Message{command: "PRIVMSG", params: ["#same", "first only"]}}, 2_000
    refute_receive {:second, %Message{command: "PRIVMSG"}}, 500
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
