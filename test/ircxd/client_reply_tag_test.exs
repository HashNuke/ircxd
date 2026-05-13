defmodule Ircxd.ClientReplyTagTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends and receives IRCv3 reply client tags" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags msgid echo-message"]

           "CAP REQ :message-tags msgid echo-message", _state ->
             [":irc.test CAP * ACK :message-tags msgid echo-message"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@msgid=parent-1 :alice!a@example.test PRIVMSG #elixir :question",
               "@msgid=child-1;+reply=parent-1 :bob!b@example.test PRIVMSG #elixir :answer"
             ]

           "@+reply=parent-1 PRIVMSG #elixir answer", _state ->
             ["@msgid=child-2;+reply=parent-1 :nick!n@example.test PRIVMSG #elixir :answer"]

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
        caps: ["message-tags", "msgid", "echo-message"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:privmsg, %{msgid: "parent-1", reply_to_msgid: nil}}}, 1_000
    assert_receive {:ircxd, {:privmsg, %{msgid: "child-1", reply_to_msgid: "parent-1"}}}, 1_000

    assert :ok = Ircxd.Client.reply(client, "#elixir", "answer", "parent-1")
    assert_receive {:scripted_irc_line, "@+reply=parent-1 PRIVMSG #elixir answer"}, 1_000
    assert_receive {:ircxd, {:privmsg, %{msgid: "child-2", reply_to_msgid: "parent-1"}}}, 1_000
  end
end
