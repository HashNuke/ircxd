defmodule Ircxd.ClientChatHistoryTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends CHATHISTORY commands and emits TARGETS results" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/chathistory batch server-time message-tags"]

           "CAP REQ :draft/chathistory batch server-time message-tags", _state ->
             [":irc.test CAP * ACK :draft/chathistory batch server-time message-tags"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "BATCH +hist1 chathistory #elixir",
               "@batch=hist1;time=2026-05-13T07:00:00.000Z;msgid=abc :alice!a@example.test PRIVMSG #elixir :from history",
               "BATCH -hist1",
               "CHATHISTORY TARGETS #elixir 2026-05-13T07:00:00.000Z"
             ]

           "CHATHISTORY LATEST #elixir * 50", _state ->
             []

           "CHATHISTORY BEFORE #elixir msgid=abc 25", _state ->
             []

           "CHATHISTORY BETWEEN #elixir timestamp=2026-05-13T07:00:00.000Z timestamp=2026-05-13T08:00:00.000Z 100",
           _state ->
             []

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["draft/chathistory", "batch", "server-time", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, {:batch_start, %{type: "chathistory", params: ["#elixir"]}}}, 1_000

    assert_receive {:ircxd, {:privmsg, %{body: "from history", batch: "hist1", msgid: "abc"}}},
                   1_000

    assert_receive {:ircxd, {:batch_end, %{ref: "hist1"}}}, 1_000

    assert_receive {:ircxd,
                    {:chathistory_target,
                     %{target: "#elixir", latest_timestamp: "2026-05-13T07:00:00.000Z"}}},
                   1_000

    assert :ok = Ircxd.Client.chathistory_latest(client, "#elixir", :latest, 50)
    assert_receive {:scripted_irc_line, "CHATHISTORY LATEST #elixir * 50"}, 1_000

    assert :ok = Ircxd.Client.chathistory_before(client, "#elixir", {:msgid, "abc"}, 25)
    assert_receive {:scripted_irc_line, "CHATHISTORY BEFORE #elixir msgid=abc 25"}, 1_000

    assert :ok =
             Ircxd.Client.chathistory_between(
               client,
               "#elixir",
               {:timestamp, "2026-05-13T07:00:00.000Z"},
               {:timestamp, "2026-05-13T08:00:00.000Z"},
               100
             )

    assert_receive {:scripted_irc_line,
                    "CHATHISTORY BETWEEN #elixir timestamp=2026-05-13T07:00:00.000Z timestamp=2026-05-13T08:00:00.000Z 100"},
                   1_000
  end

  test "rejects CHATHISTORY before draft/chathistory is negotiated" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert {:error, {:capability_not_enabled, "draft/chathistory"}} =
             Ircxd.Client.chathistory_latest(client, "#elixir", :latest, 50)

    refute_receive {:scripted_irc_line, "CHATHISTORY LATEST #elixir * 50"}, 250
  end
end
