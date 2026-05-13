defmodule Ircxd.ClientWireSizeTest do
  use ExUnit.Case, async: false

  alias Ircxd.Message
  alias Ircxd.ScriptedIrcServer

  test "rejects outbound messages that exceed IRC wire size limits" do
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

    assert {:error, :line_too_long} =
             Ircxd.Client.privmsg(client, "#chan", String.duplicate("a", 512))

    assert {:error, :line_too_long} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{
               "+draft/oversized" => String.duplicate("t", 4_095)
             })
  end

  test "rejects outbound messages with invalid command shape" do
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

    assert {:error, :invalid_command} =
             Ircxd.Client.transmit(client, %Message{command: "BAD-COMMAND", params: []})

    refute_receive {:scripted_irc_line, "BAD-COMMAND"}, 250
  end

  test "rejects outbound messages with too many parameters" do
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

    params = Enum.map(1..16, &"p#{&1}")

    assert {:error, :too_many_params} =
             Ircxd.Client.transmit(client, %Message{command: "PRIVMSG", params: params})

    refute_receive {:scripted_irc_line, "PRIVMSG p1 p2"}, 250
  end

  test "rejects outbound messages with CRLF in parameters" do
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

    assert {:error, :invalid_param} =
             Ircxd.Client.privmsg(client, "#chan", "hello\r\nOPER root secret")

    refute_receive {:scripted_irc_line, "PRIVMSG #chan :hello"}, 250
    refute_receive {:scripted_irc_line, "OPER root secret"}, 250
  end
end
