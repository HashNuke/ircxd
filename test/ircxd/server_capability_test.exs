defmodule Ircxd.ServerCapabilityTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns CAP NAK for an unsupported capability request" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "capability-client",
        username: "user",
        realname: "Ircxd capability client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "CAP", ["REQ", "missing-cap"])
    assert_receive {:ircxd, {:cap_nak, ["missing-cap"]}}, 2_000
  end

  test "accepts CAP END without returning an unknown-command error" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "cap-end-client",
        username: "user",
        realname: "Ircxd capability client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    refute_receive {:ircxd, {:irc_error, %{code: "421", target: "CAP"}}}, 250
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
