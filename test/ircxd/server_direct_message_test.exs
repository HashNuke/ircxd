defmodule Ircxd.ServerDirectMessageTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "routes PRIVMSG and NOTICE addressed to another nickname" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, alice} = start_client(server, "direct-alice")
    {:ok, bob} = start_client(server, "direct-bob")

    on_exit(fn ->
      for client <- [alice, bob], Process.alive?(client), do: GenServer.stop(client)
    end)

    wait_registered(2)

    assert :ok = Client.privmsg(alice, "direct-bob", "private hello")

    assert_receive {:ircxd,
                    {:privmsg,
                     %{nick: "direct-alice", target: "direct-bob", body: "private hello"}}},
                   2_000

    assert :ok = Client.notice(alice, "direct-bob", "private notice")

    assert_receive {:ircxd,
                    {:notice,
                     %{nick: "direct-alice", target: "direct-bob", body: "private notice"}}},
                   2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "#{nick} test client",
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
end
