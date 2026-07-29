defmodule Ircxd.ServerTagmsgTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "fans tagged TAGMSG to channel members without losing tags" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, alice} = start_client(server, "tag-alice")
    {:ok, bob} = start_client(server, "tag-bob")

    on_exit(fn ->
      for client <- [alice, bob], Process.alive?(client), do: GenServer.stop(client)
    end)

    wait_registered(2)
    wait_for_capability_acks(2)
    assert :ok = Client.join(alice, "#tags")
    assert :ok = Client.join(bob, "#tags")
    wait_for_joins(2)

    assert :ok = Client.tagmsg(alice, "#tags", %{"+typing" => "active"})
    wait_for_tagmsgs(2)
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "#{nick} test client",
      caps: ["message-tags"],
      notify: self()
    )
  end

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      _other -> wait_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, _payload}} -> wait_for_joins(remaining - 1)
      _other -> wait_for_joins(remaining)
    after
      2_000 -> flunk("clients did not join")
    end
  end

  defp wait_for_capability_acks(0), do: :ok

  defp wait_for_capability_acks(remaining) do
    receive do
      {:ircxd, {:cap_ack, ["message-tags"]}} -> wait_for_capability_acks(remaining - 1)
      _other -> wait_for_capability_acks(remaining)
    after
      2_000 -> flunk("clients did not activate message-tags")
    end
  end

  defp wait_for_tagmsgs(0), do: :ok

  defp wait_for_tagmsgs(remaining) do
    receive do
      {:ircxd, {:tagmsg, %{target: "#tags", tags: %{"+typing" => "active"}}}} ->
        wait_for_tagmsgs(remaining - 1)

      _other ->
        wait_for_tagmsgs(remaining)
    after
      2_000 -> flunk("tag message was not delivered to all members")
    end
  end
end
