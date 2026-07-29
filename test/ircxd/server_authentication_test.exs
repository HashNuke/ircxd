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

  defmodule ExternalAuthenticator do
    @behaviour Ircxd.Server.Authenticator

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def authenticate(username, password, metadata, test_pid) do
      send(test_pid, {:external_authentication_attempt, username, password, metadata})

      if username == "certificate-user" and password == "" do
        {:ok, "external-account", test_pid}
      else
        {:error, :invalid_external_identity, test_pid}
      end
    end
  end

  defmodule RaisingAuthenticator do
    @behaviour Ircxd.Server.Authenticator

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def authenticate(_username, _password, _metadata, test_pid) do
      send(test_pid, :raising_authenticator_called)
      raise "database unavailable"
    end
  end

  defmodule RejectingAuthenticator do
    @behaviour Ircxd.Server.Authenticator

    @impl true
    def init(:reject), do: {:error, :database_unavailable}

    @impl true
    def authenticate(_username, _password, _metadata, state), do: {:error, :unavailable, state}
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

  test "delegates SASL EXTERNAL identity validation to the application authenticator" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "ircxd.test",
        authenticator: {ExternalAuthenticator, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "external-auth",
        username: "certificate-user",
        realname: "Ircxd external auth client",
        sasl: {:external, "certificate-user"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:external_authentication_attempt, "certificate-user", "", _metadata},
                   2_000

    assert_receive {:ircxd, {:logged_in, %{account: "external-account"}}}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
  end

  test "contains authenticator exceptions and keeps the server available" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        authenticator: {RaisingAuthenticator, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "raising-auth",
        username: "db-user",
        realname: "Ircxd raising auth client",
        sasl: {:plain, "db-user", "secret"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive :raising_authenticator_called, 2_000
    assert_receive {:ircxd, {:sasl_failure, %{code: "904"}}}, 2_000
    assert Process.alive?(server)
    refute_receive {:ircxd, :registered}, 250
  end

  test "returns a structured error when authenticator initialization fails" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    result =
      Server.start_link(
        port: 0,
        authenticator: {RejectingAuthenticator, :reject}
      )

    Process.flag(:trap_exit, previous_trap_exit)

    assert {:error, {:authenticator_init_failed, :database_unavailable}} = result
  end

  test "rejects SASL mechanisms when no authenticator is configured" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "no-authenticator",
        username: "user",
        realname: "Ircxd no authenticator client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "AUTHENTICATE", ["PLAIN"])
    assert_receive {:ircxd, {:sasl_failure, %{code: "904"}}}, 2_000
  end
end
