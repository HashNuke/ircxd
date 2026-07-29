defmodule Ircxd.ServerOperatorTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "only the channel operator can change modes or kick members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#operators")
    assert_receive {:ircxd, {:join, %{channel: "#operators", nick: "alice"}}}, 2_000
    assert :ok = Client.join(bob, "#operators")
    assert_receive {:ircxd, {:join, %{channel: "#operators", nick: "bob"}}}, 2_000

    assert :ok = Client.names(alice, "#operators")
    assert_receive {:ircxd, {:names, %{channel: "#operators", names: names}}}, 2_000
    assert %{nick: "alice", prefixes: ["@"]} = Enum.find(names, &(&1.nick == "alice"))
    assert %{nick: "bob", prefixes: []} = Enum.find(names, &(&1.nick == "bob"))
    assert_receive {:ircxd, {:names_end, %{channel: "#operators"}}}, 2_000

    assert :ok = Client.mode(bob, "#operators", "+i")

    assert_receive {:ircxd, {:irc_error, %{code: "482", reason: "You're not channel operator"}}},
                   2_000

    assert :ok = Client.kick(bob, "#operators", "alice", "not allowed")

    assert_receive {:ircxd, {:irc_error, %{code: "482", reason: "You're not channel operator"}}},
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
