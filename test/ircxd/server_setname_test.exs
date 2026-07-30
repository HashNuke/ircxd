defmodule Ircxd.ServerSetnameTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "broadcasts SETNAME to negotiated clients and updates identity" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "setname-alice")
    {:ok, bob} = start_client(server, "setname-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_for_registered(2)
    assert :ok = Client.join(alice, "#setname")
    assert :ok = Client.join(bob, "#setname")
    wait_for_joins(2)

    assert :ok = Client.setname(alice, "Alice Updated")

    assert_receive {:ircxd, {:setname, %{nick: "setname-alice", realname: "Alice Updated"}}},
                   2_000

    assert_receive {:ircxd, {:setname, %{nick: "setname-alice", realname: "Alice Updated"}}},
                   2_000

    assert :ok = Client.whois(bob, "setname-alice")

    assert_receive {:ircxd, {:whois_user, %{nick: "setname-alice", realname: "Alice Updated"}}},
                   2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "#{nick} initial",
      caps: ["setname", "no-implicit-names"],
      notify: self()
    )
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
    assert_receive {:ircxd, {:join, %{channel: "#setname"}}}, 2_000
    wait_for_joins(remaining - 1)
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
