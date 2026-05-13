defmodule Ircxd.ClientMessageRedactionTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends REDACT and emits draft message redaction events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/message-redaction message-tags"]

           "CAP REQ :draft/message-redaction message-tags", _state ->
             [":irc.test CAP * ACK :draft/message-redaction message-tags"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "REDACT #chan msg-123 :bad example", _state ->
             [":nick!user@host REDACT #chan msg-123 :bad example"]

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
        caps: ["draft/message-redaction", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.redact(client, "#chan", "msg-123", "bad example")
    assert_receive {:scripted_irc_line, "REDACT #chan msg-123 :bad example"}, 1_000

    assert_receive {:ircxd,
                    {:redact,
                     %{
                       nick: "nick",
                       target: "#chan",
                       msgid: "msg-123",
                       reason: "bad example"
                     }}},
                   1_000
  end

  test "rejects REDACT before required capabilities are negotiated" do
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

    assert {:error, {:capability_not_enabled, "draft/message-redaction"}} =
             Ircxd.Client.redact(client, "#chan", "msg-123", "bad example")

    refute_receive {:scripted_irc_line, "REDACT #chan msg-123 :bad example"}, 250
  end

  test "rejects REDACT after draft/message-redaction is deleted" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/message-redaction message-tags"]

           "CAP REQ :draft/message-redaction message-tags", _state ->
             [":irc.test CAP * ACK :draft/message-redaction message-tags"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test CAP * DEL :draft/message-redaction"
             ]

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
        caps: ["draft/message-redaction", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_del, ["draft/message-redaction"]}}, 1_000

    assert {:error, {:capability_not_enabled, "draft/message-redaction"}} =
             Ircxd.Client.redact(client, "#chan", "msg-123", "bad example")

    refute_receive {:scripted_irc_line, "REDACT #chan msg-123 :bad example"}, 250
  end
end
