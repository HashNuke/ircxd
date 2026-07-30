defmodule Ircxd.ServerServerTimeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "adds server-time to relayed messages for clients that negotiate it" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, timed_client} = start_client(server, "timed", ["message-tags", "server-time"])
    {:ok, plain_client} = start_client(server, "plain", ["message-tags"])

    on_exit(fn ->
      stop_if_alive(timed_client)
      stop_if_alive(plain_client)
    end)

    wait_for_registration_and_capabilities(2, 2)
    assert :ok = Client.join(timed_client, "#time")
    assert :ok = Client.join(plain_client, "#time")
    wait_for_joins(2)

    assert :ok = Client.privmsg(plain_client, "#time", "hello")

    assert_receive {:ircxd, {:privmsg, %{server_time: %DateTime{} = server_time}}}, 2_000
    assert %DateTime{} = server_time
  end

  defp start_client(server, nick, caps) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      notify: self()
    )
  end

  defp wait_for_registration_and_capabilities(0, 0), do: :ok

  defp wait_for_registration_and_capabilities(registered, acks) do
    receive do
      {:ircxd, :registered} ->
        wait_for_registration_and_capabilities(registered - 1, acks)

      {:ircxd, {:cap_ack, _acked}} ->
        wait_for_registration_and_capabilities(registered, acks - 1)

      _other ->
        wait_for_registration_and_capabilities(registered, acks)
    after
      2_000 -> flunk("clients did not complete registration and capability negotiation")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#time"}}} -> wait_for_joins(remaining - 1)
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
