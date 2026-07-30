defmodule Ircxd.ServerExtendedJoinTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "sends account and realname on JOIN to extended-join clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "extended-join-client",
        username: "extended-join-client",
        realname: "Extended Join Person",
        caps: ["extended-join"],
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    wait_for_registration_and_capability()

    assert :ok = Client.join(client, "#extended")

    assert_receive {:ircxd, {:join, %{channel: "#extended", account: nil, realname: realname}}},
                   2_000

    assert realname == "Extended Join Person"
  end

  test "keeps the legacy one-parameter JOIN for clients without extended-join" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "legacy-join-client",
        username: "legacy-join-client",
        realname: "Legacy Join Person",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    wait_for_registration()
    assert :ok = Client.join(client, "#legacy")

    assert_receive {:ircxd, {:join, %{channel: "#legacy", account: nil, realname: nil}}}, 2_000
  end

  defp wait_for_registration_and_capability do
    receive do
      {:ircxd, :registered} -> wait_for_capability()
      _other -> wait_for_registration_and_capability()
    after
      2_000 -> flunk("client did not register")
    end
  end

  defp wait_for_registration do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_for_registration()
    after
      2_000 -> flunk("client did not register")
    end
  end

  defp wait_for_capability do
    receive do
      {:ircxd, {:cap_ack, ["extended-join"]}} -> :ok
      _other -> wait_for_capability()
    after
      2_000 -> flunk("client did not negotiate extended-join")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
