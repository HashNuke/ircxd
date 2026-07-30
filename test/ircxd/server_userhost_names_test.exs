defmodule Ircxd.ServerUserhostNamesTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "includes user and host in NAMES for userhost-in-names clients" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "userhost-client",
        username: "userhost-user",
        realname: "Userhost Names Client",
        caps: ["userhost-in-names"],
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    wait_for_registration()
    assert :ok = Client.join(client, "#userhosts")
    assert_receive {:ircxd, {:join, %{channel: "#userhosts"}}}, 2_000

    assert :ok = Client.names(client, "#userhosts")
    assert_receive {:ircxd, {:names, %{channel: "#userhosts", names: names}}}, 2_000

    assert %{nick: "userhost-client", user: "userhost-user", host: "ircxd.test"} =
             Enum.find(names, &(&1.nick == "userhost-client"))
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
