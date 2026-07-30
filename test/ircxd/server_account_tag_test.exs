defmodule Ircxd.ServerAccountTagTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  defmodule Authenticator do
    @behaviour Ircxd.Server.Adapter

    @impl true
    def init(_arg), do: {:ok, nil}

    @impl true
    def authenticate("tagged-user", "secret", _metadata, state),
      do: {:ok, "account-123", state}

    def authenticate(_username, _password, _metadata, state),
      do: {:ok, nil, state}
  end

  test "adds account tags to messages from authenticated users" do
    {:ok, server} =
      Server.start_link(port: 0, allow_insecure_auth: true, adapter: {Authenticator, nil})

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, sender} = start_client(server, "tagged-user", ["account-tag"], "secret")
    {:ok, receiver} = start_client(server, "tagged-receiver", ["account-tag"], "secret")
    {:ok, plain_receiver} = start_client(server, "plain-receiver", [], "secret")

    on_exit(fn ->
      stop_if_alive(sender)
      stop_if_alive(receiver)
      stop_if_alive(plain_receiver)
    end)

    wait_for_registration_and_accounts(3)
    assert :ok = Client.join(sender, "#account-tags")
    assert :ok = Client.join(receiver, "#account-tags")
    assert :ok = Client.join(plain_receiver, "#account-tags")
    wait_for_joins(3)
    Process.sleep(100)

    assert :ok = Client.privmsg(sender, "#account-tags", "tagged message")

    assert_receive {:ircxd,
                    {:message,
                     %Message{
                       command: "PRIVMSG",
                       tags: %{"account" => "account-123"},
                       params: ["#account-tags", "tagged message"]
                     }}},
                   2_000

    assert_receive {:ircxd,
                    {:message,
                     %Message{
                       command: "PRIVMSG",
                       tags: %{},
                       params: ["#account-tags", "tagged message"]
                     }}},
                   2_000
  end

  defp start_client(server, nick, caps, password) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      sasl: {:plain, nick, password},
      allow_insecure_auth: true,
      notify: self()
    )
  end

  defp wait_for_registration_and_accounts(0), do: :ok

  defp wait_for_registration_and_accounts(remaining) do
    receive do
      {:ircxd, :registered} -> wait_for_registration_and_accounts(remaining - 1)
      _other -> wait_for_registration_and_accounts(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    assert_receive {:ircxd, {:join, %{channel: "#account-tags"}}}, 2_000
    wait_for_joins(remaining - 1)
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
