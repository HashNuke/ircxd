defmodule Ircxd.ClientTaggedMessagesTest do
  use ExUnit.Case, async: false

  alias Ircxd.Message
  alias Ircxd.ScriptedIrcServer

  test "sends IRCv3 tagged client messages" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags labeled-response"]

           "CAP REQ :message-tags labeled-response", _state ->
             [":irc.test CAP * ACK :message-tags labeled-response"]

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
        caps: ["message-tags", "labeled-response"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{
               "+draft/reply" => "abc",
               "label" => "request 1"
             })

    assert_receive {:scripted_irc_line,
                    "@+draft/reply=abc;label=request\\s1 PRIVMSG #chan hello"},
                   1_000

    assert :ok =
             Ircxd.Client.transmit(client, %Message{
               command: "NOTICE",
               params: ["nick", "tagged notice"],
               tags: %{"label" => "notice-1"}
             })

    assert_receive {:scripted_irc_line, "@label=notice-1 NOTICE nick :tagged notice"}, 1_000
  end

  test "rejects label tags before labeled-response is negotiated" do
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

    assert {:error, {:capability_not_enabled, "labeled-response"}} =
             Ircxd.Client.labeled_raw(client, "request-1", "WHOIS", ["alice"])

    refute_receive {:scripted_irc_line, "@label=request-1 WHOIS alice"}, 250
  end

  test "rejects malformed outbound IRCv3 tag keys" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags"]

           "CAP REQ message-tags", _state ->
             [":irc.test CAP * ACK :message-tags"]

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
        caps: ["message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert {:error, :invalid_tag_key} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{"bad key" => "value"})

    assert {:error, :invalid_tag_key} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{"bad;key" => "value"})

    assert {:error, :invalid_tag_key} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{"+bad\r\nkey" => "value"})

    refute_receive {:scripted_irc_line, "@bad"}, 250
    refute_receive {:scripted_irc_line, "key=value PRIVMSG #chan hello"}, 250
  end

  test "rejects client-only tags before message-tags is negotiated" do
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

    assert {:error, {:capability_not_enabled, "message-tags"}} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{"+draft/reply" => "abc"})

    refute_receive {:scripted_irc_line, "@+draft/reply=abc PRIVMSG #chan hello"}, 250
  end

  test "rejects client-only tags after message-tags is deleted" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags"]

           "CAP REQ message-tags", _state ->
             [":irc.test CAP * ACK :message-tags"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome", ":irc.test CAP * DEL :message-tags"]

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
        caps: ["message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_del, ["message-tags"]}}, 1_000

    assert {:error, {:capability_not_enabled, "message-tags"}} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{"+draft/reply" => "abc"})

    refute_receive {:scripted_irc_line, "@+draft/reply=abc PRIVMSG #chan hello"}, 250
  end

  test "rejects label tags after labeled-response is deleted" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags labeled-response"]

           "CAP REQ :message-tags labeled-response", _state ->
             [":irc.test CAP * ACK :message-tags labeled-response"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test CAP * DEL :labeled-response"
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
        caps: ["message-tags", "labeled-response"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_del, ["labeled-response"]}}, 1_000

    assert {:error, {:capability_not_enabled, "labeled-response"}} =
             Ircxd.Client.labeled_raw(client, "request-1", "WHOIS", ["alice"])

    refute_receive {:scripted_irc_line, "@label=request-1 WHOIS alice"}, 250
  end
end
