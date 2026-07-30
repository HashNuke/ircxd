defmodule Ircxd.ServerWhowasTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns nickname history after a nick change and disconnect" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "alice")
    {:ok, bob} = start_client(server, "bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.nick(alice, "alice-new")
    wait_for_nick(alice, "alice-new")

    assert :ok = Client.whowas(bob, "alice", 1)
    assert_receive {:ircxd, {:whowas_user, %{nick: "alice", username: "alice"}}}, 2_000
    assert_receive {:ircxd, {:whowas_end, %{nick: "alice"}}}, 2_000

    stop_if_alive(alice)
    Process.sleep(100)
    assert :ok = Client.whowas(bob, "alice-new")
    assert_receive {:ircxd, {:whowas_user, %{nick: "alice-new", username: "alice"}}}, 2_000
    assert_receive {:ircxd, {:whowas_end, %{nick: "alice-new"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      notify: self()
    )
  end

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      _other -> wait_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_nick(client, nick) do
    if :sys.get_state(client).current_nick == nick do
      :ok
    else
      Process.sleep(10)
      wait_for_nick(client, nick)
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
