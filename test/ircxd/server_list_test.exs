defmodule Ircxd.ServerListTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns channel names, member counts, and topics from LIST" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "list-alice")
    {:ok, bob} = start_client(server, "list-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#listed")
    assert :ok = Client.join(bob, "#listed")
    wait_for_joins(2)
    assert :ok = Client.topic(alice, "#listed", "A listed channel")
    assert_receive {:ircxd, {:topic, %{topic: "A listed channel"}}}, 2_000
    assert_receive {:ircxd, {:topic, %{topic: "A listed channel"}}}, 2_000

    assert :ok = Client.list(alice)

    assert_receive {:ircxd, {:list_start, %{params: ["list-alice", "Channel", "Users Name"]}}},
                   2_000

    assert_receive {:ircxd,
                    {:list_entry, %{channel: "#listed", visible: "2", topic: "A listed channel"}}},
                   2_000

    assert_receive {:ircxd, {:list_end, %{params: ["list-alice", "End of /LIST"]}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd list client",
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
      {:ircxd, {:join, %{channel: "#listed"}}} -> wait_for_joins(remaining - 1)
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
