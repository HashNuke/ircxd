defmodule Ircxd.ServerAuthenticationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  @cacertfile Path.expand("../support/tls/ca.crt", __DIR__)
  @server_certfile Path.expand("../support/tls/server.crt", __DIR__)
  @server_keyfile Path.expand("../support/tls/server.key", __DIR__)
  @client_certfile Path.expand("../support/tls/client.crt", __DIR__)
  @client_keyfile Path.expand("../support/tls/client.key", __DIR__)

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
    def init({test_pid, expected_fingerprint}),
      do: {:ok, %{test_pid: test_pid, expected_fingerprint: expected_fingerprint}}

    @impl true
    def authenticate(username, password, metadata, state) do
      send(
        state.test_pid,
        {:external_authentication_attempt, username, password, metadata}
      )

      if username == "certificate-user" and password == "" and
           metadata.mechanism == :external and metadata.tls? and
           is_binary(metadata.peer_certificate) and
           metadata.peer_certificate_sha256 == state.expected_fingerprint do
        {:ok, "external-account", state}
      else
        {:error, :invalid_external_identity, state}
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

    assert_receive {:authentication_attempt, "db-user", "secret",
                    %{
                      server: "ircxd.test",
                      mechanism: :plain,
                      transport: :gen_tcp,
                      tls?: false,
                      peer: {{127, 0, 0, 1}, _port},
                      peer_certificate: nil
                    }},
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
    expected_fingerprint = certificate_fingerprint(@client_certfile)

    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "ircxd.test",
        tls: true,
        tls_options: [
          certfile: @server_certfile,
          keyfile: @server_keyfile,
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          cacertfile: @cacertfile
        ],
        external_auth: true,
        authenticator: {ExternalAuthenticator, {self(), expected_fingerprint}}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "localhost",
        port: Server.port(server),
        tls: true,
        tls_options: [
          cacertfile: @cacertfile,
          certfile: @client_certfile,
          keyfile: @client_keyfile
        ],
        nick: "external-auth",
        username: "certificate-user",
        realname: "Ircxd external auth client",
        sasl: {:external, "certificate-user"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:external_authentication_attempt, "certificate-user", "",
                    %{
                      mechanism: :external,
                      transport: :ssl,
                      tls?: true,
                      peer_certificate: certificate,
                      peer_certificate_sha256: fingerprint
                    }},
                   2_000

    assert is_binary(certificate)
    assert fingerprint == expected_fingerprint
    assert_receive {:ircxd, {:logged_in, %{account: "external-account"}}}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
  end

  test "rejects SASL EXTERNAL when certificate authentication is not configured" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        authenticator: {ExternalAuthenticator, {self(), "unused"}}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "unsafe-external",
        username: "certificate-user",
        realname: "Unsafe external auth",
        sasl: {:external, "certificate-user"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)

    assert_receive {:ircxd, {:sasl_failure, %{code: "904"}}}, 2_000
    refute_receive {:external_authentication_attempt, _, _, _}, 250
    refute_receive {:ircxd, :registered}, 250
  end

  test "rejects unsafe server-side EXTERNAL configuration at startup" do
    assert {:error, :external_auth_requires_tls} =
             Server.start_link(
               port: 0,
               external_auth: true,
               authenticator: {ExternalAuthenticator, {self(), "unused"}}
             )

    assert {:error, :external_auth_requires_verified_client_certificates} =
             Server.start_link(
               port: 0,
               tls: true,
               tls_options: [certfile: @server_certfile, keyfile: @server_keyfile],
               external_auth: true,
               authenticator: {ExternalAuthenticator, {self(), "unused"}}
             )
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

  test "returns 904 for an unsupported SASL mechanism" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        authenticator: {Authenticator, self()}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "unsupported-sasl",
        username: "user",
        realname: "Ircxd unsupported SASL client",
        sasl: {:plain, "db-user", "secret"},
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "AUTHENTICATE", ["SCRAM-SHA-256"])

    assert_receive {:ircxd,
                    {:sasl_failure,
                     %{
                       code: "904",
                       message: %Ircxd.Message{params: [_, "Unsupported SASL mechanism"]}
                     }}},
                   2_000
  end

  defp certificate_fingerprint(path) do
    path
    |> File.read!()
    |> :public_key.pem_decode()
    |> hd()
    |> elem(1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
