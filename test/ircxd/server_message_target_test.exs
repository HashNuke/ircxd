defmodule Ircxd.ServerMessageTargetTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns target errors for invalid PRIVMSG destinations" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "target-alice")
    {:ok, bob} = start_client(server, "target-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#target")
    assert_receive {:ircxd, {:join, %{channel: "#target"}}}, 2_000

    assert :ok = Client.privmsg(bob, "#target", "hello")
    assert_receive {:ircxd, {:irc_error, %{code: "404", target: "#target"}}}, 2_000

    assert :ok = Client.privmsg(alice, "#missing", "hello")
    assert_receive {:ircxd, {:irc_error, %{code: "403", target: "#missing"}}}, 2_000

    assert :ok = Client.privmsg(alice, "ghost", "hello")
    assert_receive {:ircxd, {:irc_error, %{code: "401", target: "ghost"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd target client",
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
