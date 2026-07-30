defmodule Ircxd.ServerAccountNotifyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  defmodule Authenticator do
    @behaviour Ircxd.Server.Authenticator

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def authenticate("account-user", password, metadata, test_pid) do
      send(test_pid, {:account_authentication, password, metadata})

      case password do
        "secret" -> {:ok, "account-123", test_pid}
        "changed" -> {:ok, "account-456", test_pid}
        _ -> {:error, :invalid_credentials, test_pid}
      end
    end

    def authenticate("account-observer", "secret", metadata, test_pid) do
      send(test_pid, {:account_authentication, "observer", metadata})
      {:ok, nil, test_pid}
    end

    def authenticate(_username, _password, _metadata, state),
      do: {:error, :invalid_credentials, state}
  end

  test "notifies an authenticated client of its account with account-notify" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        allow_insecure_auth: true,
        authenticator: {Authenticator, self()}
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "account-user",
        username: "client-user",
        realname: "Account Notify Client",
        caps: ["account-notify"],
        sasl: {:plain, "account-user", "secret"},
        allow_insecure_auth: true,
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)

    assert_receive {:ircxd, {:logged_in, %{account: "account-123"}}}, 2_000
    assert_receive {:ircxd, {:account, %{nick: "account-user", account: "account-123"}}}, 2_000
  end

  test "notifies common-channel clients when a registered account changes" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        allow_insecure_auth: true,
        authenticator: {Authenticator, self()}
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, target} = start_client(server, "account-user", ["account-notify"], "secret")
    {:ok, observer} = start_client(server, "account-observer", ["account-notify"], "secret")

    on_exit(fn ->
      stop_if_alive(target)
      stop_if_alive(observer)
    end)

    assert_receive {:account_authentication, "secret", %{nick: "account-user"} = metadata}, 2_000
    assert_receive {:ircxd, {:logged_in, %{account: "account-123"}}}, 2_000
    assert_receive {:ircxd, {:account, %{account: "account-123"}}}, 2_000
    wait_for_registered(2)

    assert :ok = Client.join(target, "#accounts")
    assert :ok = Client.join(observer, "#accounts")
    wait_for_joins(2)

    assert {:ok, "account-456"} =
             Server.authenticate(server, "account-user", "changed", metadata)

    assert_receive {:account_authentication, "changed", _}, 2_000
    assert_receive {:ircxd, {:account, %{nick: "account-user", account: "account-456"}}}, 2_000
    assert_receive {:ircxd, {:account, %{nick: "account-user", account: "account-456"}}}, 2_000
  end

  defp start_client(server, nick, caps, password) do
    opts = [
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      allow_insecure_auth: true,
      notify: self()
    ]

    opts = if password, do: Keyword.put(opts, :sasl, {:plain, nick, password}), else: opts
    Client.start_link(opts)
  end

  defp wait_for_registered(0), do: :ok

  defp wait_for_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_for_registered(remaining - 1)
      _other -> wait_for_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#accounts"}}} -> wait_for_joins(remaining - 1)
      _other -> wait_for_joins(remaining)
    after
      2_000 -> flunk("clients did not join")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
