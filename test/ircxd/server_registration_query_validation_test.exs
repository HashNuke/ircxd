defmodule Ircxd.ServerRegistrationQueryValidationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns the standard errors for commands missing required parameters" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "missing-parameters")
    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "NICK", [])
    assert_receive {:ircxd, {:irc_error, %{code: "431", reason: "No nickname given"}}}, 2_000

    assert :ok = Client.raw(client, "PASS", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "PASS"}}}, 2_000

    assert :ok = Client.raw(client, "AUTHENTICATE", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "AUTHENTICATE"}}}, 2_000

    assert :ok = Client.raw(client, "TOPIC", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "TOPIC"}}}, 2_000

    assert :ok = Client.raw(client, "WHOIS", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "WHOIS"}}}, 2_000

    assert :ok = Client.raw(client, "PING", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "PING"}}}, 2_000
  end

  test "returns 461 for incomplete USER during registration" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "bad*nick")
    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, {:irc_error, %{code: "432"}}}, 2_000

    assert :ok = Client.raw(client, "USER", [])
    assert_receive {:ircxd, {:irc_error, %{code: "461", target: "USER"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      allow_insecure_auth: true,
      nick: nick,
      username: nick,
      realname: "Ircxd validation client",
      notify: self()
    )
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
