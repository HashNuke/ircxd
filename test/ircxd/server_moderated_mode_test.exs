defmodule Ircxd.ServerModeratedModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "+m permits operator messages and rejects non-operator messages" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#moderated")
    assert_receive {:ircxd, {:join, %{channel: "#moderated", nick: "alice"}}}, 2_000
    assert :ok = Client.join(bob, "#moderated")
    assert_receive {:ircxd, {:join, %{channel: "#moderated", nick: "bob"}}}, 2_000

    assert :ok = Client.mode(alice, "#moderated", "+m")
    assert_receive {:ircxd, {:mode, %{target: "#moderated", modes: "+m"}}}, 2_000

    assert :ok = Client.privmsg(bob, "#moderated", "not allowed")
    assert_receive {:ircxd, {:irc_error, %{code: "404", reason: "Cannot send to channel"}}}, 2_000

    assert :ok = Client.privmsg(alice, "#moderated", "operator message")
    assert_receive {:ircxd, {:privmsg, %{target: "#moderated", body: "operator message"}}}, 2_000
    assert_receive {:ircxd, {:privmsg, %{target: "#moderated", body: "operator message"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
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
