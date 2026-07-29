defmodule Ircxd.ServerAuthenticationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  defmodule Authenticator do
    @behaviour Ircxd.Server.Authenticator

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def authenticate(username, password, metadata, test_pid) do
      send(test_pid, {:authentication_attempt, username, password, metadata})

      if username == "db-user" and password == "secret" do
        {:ok, "account-123", test_pid}
      else
        {:error, :invalid_credentials, test_pid}
      end
    end
  end

  test "authenticator controls SASL registration using application-owned state" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "ircxd.test",
        authenticator: {Authenticator, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "auth-test",
        username: "client-user",
        realname: "Ircxd auth client",
        sasl: {:plain, "db-user", "secret"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:authentication_attempt, "db-user", "secret", %{server: "ircxd.test"}},
                   2_000

    assert_receive {:ircxd, {:logged_in, %{account: "account-123"}}}, 2_000

    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.whois(client, "auth-test")
    assert_receive {:ircxd, {:whois_account, %{nick: "auth-test", account: "account-123"}}}, 2_000
  end

  test "does not register clients when the authenticator rejects credentials" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "ircxd.test",
        authenticator: {Authenticator, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "auth-failure",
        username: "client-user",
        realname: "Ircxd auth client",
        sasl: {:plain, "db-user", "wrong"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:authentication_attempt, "db-user", "wrong", _metadata}, 2_000
    refute_receive {:ircxd, :registered}, 500
  end

  test "allows a client to abort an in-progress SASL exchange" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "ircxd.test",
        authenticator: {Authenticator, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "auth-abort",
        username: "client-user",
        realname: "Ircxd auth abort client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:ircxd, {:connected, _}}, 2_000
    assert :ok = Client.raw(client, "AUTHENTICATE", ["*"])
    assert_receive {:ircxd, {:sasl_failure, %{code: "906"}}}, 2_000
    refute_receive {:authentication_attempt, _, _, _}, 250
    refute_receive {:ircxd, :registered}, 250
  end
end
