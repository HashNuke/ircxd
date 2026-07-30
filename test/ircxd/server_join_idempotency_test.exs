defmodule Ircxd.ServerJoinIdempotencyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "does not publish a second JOIN when a client repeats JOIN" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "repeat-client",
        username: "repeat-client",
        realname: "Ircxd repeat client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    wait_registered()

    assert :ok = Client.join(client, "#repeat")
    assert_receive {:ircxd, {:join, %{channel: "#repeat"}}}, 2_000

    assert :ok = Client.join(client, "#repeat")
    refute_receive {:ircxd, {:join, %{channel: "#repeat"}}}, 250
  end

  defp wait_registered do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_registered()
    after
      2_000 -> flunk("client did not register")
    end
  end
end
