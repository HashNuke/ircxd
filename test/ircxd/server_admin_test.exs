defmodule Ircxd.ServerAdminTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "serves configured ADMIN information" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        server_name: "admin.test",
        admin: %{location: ["Operations HQ", "Network Team"], email: "admin@test.example"}
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "admin-client",
        username: "user",
        realname: "Ircxd ADMIN client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.admin(client)
    assert_receive {:ircxd, {:admin_start, %{server: "admin.test"}}}, 2_000
    assert_receive {:ircxd, {:admin_location, %{line: 1, text: "Operations HQ"}}}, 2_000
    assert_receive {:ircxd, {:admin_location, %{line: 2, text: "Network Team"}}}, 2_000
    assert_receive {:ircxd, {:admin_email, %{text: "admin@test.example"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
