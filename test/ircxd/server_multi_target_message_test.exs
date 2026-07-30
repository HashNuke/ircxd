defmodule Ircxd.ServerMultiTargetMessageTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "routes comma-separated PRIVMSG targets independently" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")
    {:ok, carol} = start_client(server, "carol")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
      stop_if_alive(carol)
    end)

    wait_registered(3)
    assert :ok = Client.join(alice, "#one")
    assert_receive {:ircxd, {:join, %{channel: "#one", nick: "alice"}}}, 2_000
    assert :ok = Client.join(bob, "#one")
    assert_receive {:ircxd, {:join, %{channel: "#one", nick: "bob"}}}, 2_000
    assert :ok = Client.join(alice, "#two")
    assert_receive {:ircxd, {:join, %{channel: "#two", nick: "alice"}}}, 2_000
    assert :ok = Client.join(carol, "#two")
    assert_receive {:ircxd, {:join, %{channel: "#two", nick: "carol"}}}, 2_000

    assert :ok = Client.privmsg(alice, "#one,#two", "hello everywhere")

    assert_receive {:ircxd,
                    {:privmsg, %{target: "#one", body: "hello everywhere", nick: "alice"}}},
                   2_000

    assert_receive {:ircxd,
                    {:privmsg, %{target: "#two", body: "hello everywhere", nick: "alice"}}},
                   2_000

    assert :ok = Client.notice(alice, "#one,#two", "notice everywhere")

    assert_receive {:ircxd,
                    {:notice, %{target: "#one", body: "notice everywhere", nick: "alice"}}},
                   2_000

    assert_receive {:ircxd,
                    {:notice, %{target: "#two", body: "notice everywhere", nick: "alice"}}},
                   2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: ["echo-message"],
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

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
