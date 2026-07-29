defmodule Ircxd.ServerAccountNotifyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  defmodule Authenticator do
    @behaviour Ircxd.Server.Authenticator

    @impl true
    def init(_arg), do: {:ok, nil}

    @impl true
    def authenticate("account-user", "secret", _metadata, state),
      do: {:ok, "account-123", state}

    def authenticate(_username, _password, _metadata, state),
      do: {:error, :invalid_credentials, state}
  end

  test "notifies an authenticated client of its account with account-notify" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        authenticator: {Authenticator, nil}
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
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)

    assert_receive {:ircxd, {:logged_in, %{account: "account-123"}}}, 2_000
    assert_receive {:ircxd, {:account, %{nick: "account-user", account: "account-123"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
