defmodule Ircxd.ServerIsupportTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "advertises configurable ISUPPORT tokens during registration" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        isupport: ["CHANTYPES=#&", "NICKLEN=24", "CASEMAPPING=ascii"]
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "isupport-client",
        username: "user",
        realname: "Ircxd ISUPPORT client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, {:isupport, tokens}}, 2_000
    assert tokens["CHANTYPES"] == "#&"
    assert tokens["NICKLEN"] == "24"
    assert tokens["CASEMAPPING"] == "ascii"
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
