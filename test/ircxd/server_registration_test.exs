defmodule Ircxd.ServerRegistrationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "accepts a registration from Ircxd.Client" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "registration",
        username: "user",
        realname: "Ircxd test client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)

    assert_receive {:ircxd, :registered}, 2_000
  end

  test "rejects duplicate nicknames and permits the client's retry" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, first} = start_client(server, "collision")
    on_exit(fn -> stop_if_alive(first) end)
    wait_registered()

    {:ok, second} =
      start_client(server, "collision",
        nick_retry_fun: fn _attempted, _state -> "collision-retry" end
      )

    on_exit(fn -> stop_if_alive(second) end)

    assert_receive {:ircxd, {:nick_in_use, %{attempted: "collision", next: "collision-retry"}}},
                   2_000

    assert_receive {:ircxd, :registered}, 2_000
  end

  defp start_client(server, nick, extra \\ []) do
    Client.start_link(
      [
        host: "127.0.0.1",
        port: Server.port(server),
        nick: nick,
        username: nick,
        realname: "Ircxd registration client",
        notify: self()
      ] ++ extra
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

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
