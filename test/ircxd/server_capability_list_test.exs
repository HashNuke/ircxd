defmodule Ircxd.ServerCapabilityListTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns the connection's active capabilities for CAP LIST" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "cap-list-client",
        username: "user",
        realname: "Ircxd capability list client",
        caps: ["echo-message"],
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, {:cap_ack, ["echo-message"]}}, 2_000

    assert :ok = Client.cap_list(client)
    assert_receive {:ircxd, {:cap_list, %{"echo-message" => true}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
