defmodule Ircxd.ClientMsgidDedupeTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "optionally marks and emits duplicate msgid events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags msgid"]

           "CAP REQ :message-tags msgid", _state ->
             [":irc.test CAP * ACK :message-tags msgid"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@msgid=abc :alice!a@example.test PRIVMSG #elixir :hello",
               "@msgid=abc :alice!a@example.test PRIVMSG #elixir :hello again"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["message-tags", "msgid"],
        msgid_dedupe: :mark,
        notify: self()
      )

    assert_receive {:ircxd, {:privmsg, %{body: "hello", msgid: "abc", duplicate_msgid?: false}}},
                   1_000

    assert_receive {:ircxd,
                    {:duplicate_msgid, %{msgid: "abc", event: {:privmsg, %{body: "hello again"}}}}},
                   1_000

    assert_receive {:ircxd,
                    {:privmsg, %{body: "hello again", msgid: "abc", duplicate_msgid?: true}}},
                   1_000
  end
end
