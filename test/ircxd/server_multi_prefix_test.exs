defmodule Ircxd.ServerMultiPrefixTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns all channel prefixes to multi-prefix clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "multi-prefix-client",
        username: "multi-prefix-client",
        realname: "Multi Prefix Client",
        caps: ["multi-prefix"],
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    wait_for_registration()

    assert :ok = Client.join(client, "#prefixes")
    assert_receive {:ircxd, {:join, %{channel: "#prefixes"}}}, 2_000

    assert :ok = Client.mode(client, "#prefixes", "+v", ["multi-prefix-client"])
    assert_receive {:ircxd, {:mode, %{modes: "+v"}}}, 2_000

    assert :ok = Client.names(client, "#prefixes")
    assert_receive {:ircxd, {:names, %{channel: "#prefixes", names: names}}}, 2_000

    assert %{nick: "multi-prefix-client", prefixes: ["@", "+"]} =
             Enum.find(names, &(&1.nick == "multi-prefix-client"))
  end

  defp wait_for_registration do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_for_registration()
    after
      2_000 -> flunk("client did not register")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
