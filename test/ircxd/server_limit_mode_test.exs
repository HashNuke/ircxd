defmodule Ircxd.ServerLimitModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "+l rejects JOIN when the channel reaches its member limit" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#limited")
    assert_receive {:ircxd, {:join, %{channel: "#limited", nick: "alice"}}}, 2_000

    assert :ok = Client.mode(alice, "#limited", "+l", ["1"])
    assert_receive {:ircxd, {:mode, %{target: "#limited", modes: "+l"}}}, 2_000

    assert :ok = Client.join(bob, "#limited")

    assert_receive {:ircxd, {:irc_error, %{code: "471", reason: "Cannot join channel (+l)"}}},
                   2_000
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
