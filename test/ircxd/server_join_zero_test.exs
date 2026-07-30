defmodule Ircxd.ServerJoinZeroTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "JOIN 0 parts the client from every joined channel" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server)
    on_exit(fn -> stop_if_alive(client) end)

    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.raw(client, "JOIN", ["#zero-one,#zero-two"])
    assert_receive {:ircxd, {:join, %{channel: "#zero-one"}}}, 2_000
    assert_receive {:ircxd, {:join, %{channel: "#zero-two"}}}, 2_000

    assert :ok = Client.raw(client, "JOIN", ["0"])
    assert_receive {:ircxd, {:part, %{channel: "#zero-one"}}}, 2_000
    assert_receive {:ircxd, {:part, %{channel: "#zero-two"}}}, 2_000
  end

  defp start_client(server) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: "join-zero",
      username: "join-zero",
      realname: "Ircxd JOIN zero client",
      caps: ["no-implicit-names"],
      notify: self()
    )
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
