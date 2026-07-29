defmodule Ircxd.ServerMessageIdTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "assigns one message id to a relayed message for tagged clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "id-alice")
    {:ok, bob} = start_client(server, "id-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_for_registration_and_capabilities(2, 2)
    assert :ok = Client.join(alice, "#ids")
    assert :ok = Client.join(bob, "#ids")
    wait_for_joins(2)

    assert :ok = Client.privmsg(alice, "#ids", "hello")
    assert_receive {:ircxd, {:privmsg, %{msgid: msgid}}}, 2_000
    assert is_binary(msgid)
    assert msgid != ""
    assert_receive {:ircxd, {:privmsg, %{msgid: ^msgid}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: ["message-tags"],
      notify: self()
    )
  end

  defp wait_for_registration_and_capabilities(0, 0), do: :ok

  defp wait_for_registration_and_capabilities(registered, capabilities) do
    receive do
      {:ircxd, :registered} ->
        wait_for_registration_and_capabilities(registered - 1, capabilities)

      {:ircxd, {:cap_ack, _acked}} ->
        wait_for_registration_and_capabilities(registered, capabilities - 1)

      _other ->
        wait_for_registration_and_capabilities(registered, capabilities)
    after
      2_000 -> flunk("clients did not complete registration and capability negotiation")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#ids"}}} -> wait_for_joins(remaining - 1)
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
