defmodule Ircxd.ServerMultilineTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "relays draft multiline messages as a combined client event" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    caps = ["batch", "draft/multiline", "message-tags"]
    {:ok, sender} = start_client(server, "multiline-sender", caps)
    {:ok, receiver} = start_client(server, "multiline-receiver", caps)

    on_exit(fn ->
      stop_if_alive(sender)
      stop_if_alive(receiver)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.join(sender, "#multiline")
    assert_receive {:ircxd, {:join, %{channel: "#multiline"}}}, 2_000
    assert :ok = Client.join(receiver, "#multiline")
    assert_receive {:ircxd, {:join, %{channel: "#multiline"}}}, 2_000

    assert :ok = Client.multiline_privmsg(sender, "#multiline", "hello\n\nworld")

    assert_receive {:ircxd,
                    {:multiline,
                     %{target: "#multiline", command: "PRIVMSG", body: "hello\n\nworld"}}},
                   2_000
  end

  defp start_client(server, nick, caps) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      notify: self()
    )
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
