defmodule Ircxd.ServerProtocolErrorsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns 421 for an unknown command" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "unknown-command")
    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "BOGUS", [])

    assert_receive {:ircxd, {:irc_error, %{code: "421", reason: "Unknown command"}}}, 2_000
  end

  test "returns 461 when PART has no channel parameter" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "part-parameters")
    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "PART", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "PART"}}}, 2_000
  end

  test "returns 451 when an unregistered client sends a command" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "bad*nick")
    on_exit(fn -> stop_if_alive(client) end)

    assert_receive {:ircxd, {:irc_error, %{code: "432"}}}, 2_000
    assert :ok = Client.raw(client, "JOIN", ["#not-registered"])

    assert_receive {:ircxd, {:irc_error, %{code: "451", reason: "You have not registered"}}},
                   2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd protocol error client",
      notify: self()
    )
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
