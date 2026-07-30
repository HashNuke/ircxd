defmodule Ircxd.ServerChatHistoryTargetsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "lists visible channels with recent history timestamps" do
    {:ok, server} = Server.start_link(port: 0, history_limit: 10)
    on_exit(fn -> stop_if_alive(server) end)

    caps = ["draft/chathistory", "batch", "message-tags", "server-time"]
    {:ok, sender} = start_client(server, "targets-sender", caps)
    {:ok, reader} = start_client(server, "targets-reader", caps)

    on_exit(fn ->
      stop_if_alive(sender)
      stop_if_alive(reader)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000

    for channel <- ["#history", "#other"] do
      assert :ok = Client.join(sender, channel)
      assert_receive {:ircxd, {:join, %{channel: ^channel}}}, 2_000
      assert :ok = Client.join(reader, channel)
      assert_receive {:ircxd, {:join, %{channel: ^channel}}}, 2_000
    end

    assert :ok = Client.privmsg(sender, "#history", "history message")
    assert_receive {:ircxd, {:privmsg, %{body: "history message"}}}, 2_000
    assert :ok = Client.privmsg(sender, "#other", "other message")
    assert_receive {:ircxd, {:privmsg, %{body: "other message"}}}, 2_000

    assert :ok =
             Client.chathistory_targets(
               reader,
               {:timestamp, "2026-01-01T00:00:00.000Z"},
               {:timestamp, "2027-01-01T00:00:00.000Z"},
               10
             )

    assert_receive {:ircxd,
                    {:chathistory_target,
                     %{target: "#history", latest_timestamp: history_timestamp}}},
                   2_000

    assert_receive {:ircxd,
                    {:chathistory_target, %{target: "#other", latest_timestamp: other_timestamp}}},
                   2_000

    assert history_timestamp != other_timestamp
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
