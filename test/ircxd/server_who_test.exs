defmodule Ircxd.ServerWhoTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns channel member identity from WHO" do
    {:ok, server} = Server.start_link(port: 0, server_name: "who.test")
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "who-client",
        username: "who-user",
        realname: "Ircxd WHO client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.join(client, "#who")
    assert_receive {:ircxd, {:join, %{channel: "#who"}}}, 2_000

    assert :ok = Client.who(client, "#who")

    assert_receive {:ircxd,
                    {:who_reply,
                     %{
                       channel: "#who",
                       nick: "who-client",
                       username: "who-user",
                       realname: "Ircxd WHO client"
                     }}},
                   2_000

    assert_receive {:ircxd, {:who_end, %{mask: "#who"}}}, 2_000
  end

  test "returns an online nickname from WHO" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "who-nick",
        username: "who-user",
        realname: "Ircxd WHO nickname client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.who(client, "who-nick")

    assert_receive {:ircxd,
                    {:who_reply, %{channel: "*", nick: "who-nick", username: "who-user"}}},
                   2_000

    assert_receive {:ircxd, {:who_end, %{mask: "who-nick"}}}, 2_000
  end

  test "WHO without a mask returns visible registered users" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "who-all",
        username: "who-user",
        realname: "Ircxd WHO all client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.raw(client, "WHO", [])

    assert_receive {:ircxd, {:who_reply, %{channel: "*", nick: "who-all"}}}, 2_000
    assert_receive {:ircxd, {:who_end, %{mask: "*"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
