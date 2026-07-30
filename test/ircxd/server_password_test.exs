defmodule Ircxd.ServerPasswordTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "registers a client when its PASS matches the configured server password" do
    {:ok, server} = Server.start_link(port: 0, password: "secret", allow_insecure_auth: true)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        password: "secret",
        allow_insecure_auth: true,
        nick: "password-ok",
        username: "client-user",
        realname: "Ircxd password client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
  end

  test "rejects an incorrect PASS and leaves the client unregistered" do
    {:ok, server} = Server.start_link(port: 0, password: "secret", allow_insecure_auth: true)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        password: "wrong",
        allow_insecure_auth: true,
        nick: "password-bad",
        username: "client-user",
        realname: "Ircxd password client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)

    assert_receive {:ircxd, {:irc_error, %{code: "464", reason: "Password incorrect"}}}, 2_000
    refute_receive {:ircxd, :registered}, 500
  end

  test "rejects PASS over cleartext unless explicitly enabled" do
    {:ok, server} = Server.start_link(port: 0, password: "secret")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "insecure-password",
        username: "client-user",
        realname: "Ircxd insecure password client",
        allow_insecure_auth: true,
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert :ok = Client.raw(client, "PASS", ["secret"])

    assert_receive {:ircxd,
                    {:irc_error, %{code: "464", reason: "Insecure authentication is disabled"}}},
                   2_000

    refute_receive {:ircxd, :registered}, 500
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
