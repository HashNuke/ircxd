defmodule Ircxd.ServerChannelsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns NAMES and removes a client on PART" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} = start_client(server)
    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    wait_registered()

    assert :ok = Client.join(client, "#channels")
    wait_for_join()

    assert :ok = Client.names(client, "#channels")

    assert_receive {:ircxd, {:names, %{channel: "#channels", names: names}}}, 2_000
    assert Enum.any?(names, &(&1.nick == "channel-client"))
    assert_receive {:ircxd, {:names_end, %{channel: "#channels"}}}, 2_000

    assert :ok = Client.part(client, "#channels", "leaving")
    assert_receive {:ircxd, {:part, %{channel: "#channels", reason: "leaving"}}}, 2_000
  end

  defp start_client(server) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: "channel-client",
      username: "channel-client",
      realname: "Ircxd channel client",
      notify: self()
    )
  end

  defp wait_registered do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_registered()
    after
      2_000 -> flunk("client did not register")
    end
  end

  defp wait_for_join do
    receive do
      {:ircxd, {:join, %{channel: "#channels"}}} -> :ok
      _other -> wait_for_join()
    after
      2_000 -> flunk("client did not join")
    end
  end
end
