defmodule Ircxd.ServerChatHistoryTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "serves recent channel messages through CHATHISTORY LATEST" do
    {:ok, server} = Server.start_link(port: 0, history_limit: 10)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, sender} = start_client(server, "history-sender", ["message-tags"])

    {:ok, reader} =
      start_client(server, "history-reader", ["draft/chathistory", "batch", "message-tags"])

    on_exit(fn ->
      stop_if_alive(sender)
      stop_if_alive(reader)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.join(sender, "#history")
    assert_receive {:ircxd, {:join, %{channel: "#history"}}}, 2_000
    assert :ok = Client.join(reader, "#history")
    assert_receive {:ircxd, {:join, %{channel: "#history"}}}, 2_000

    assert :ok = Client.privmsg(sender, "#history", "saved message")
    assert_receive {:ircxd, {:privmsg, %{body: "saved message"}}}, 2_000

    assert :ok = Client.chathistory_latest(reader, "#history", :latest, 10)
    assert_receive {:ircxd, {:batch_start, %{type: "chathistory", params: ["#history"]}}}, 2_000

    assert_receive {:ircxd,
                    {:privmsg, %{target: "#history", body: "saved message", batch: _reference}}},
                   2_000

    assert_receive {:ircxd, {:batch_end, %{ref: _reference}}}, 2_000
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
