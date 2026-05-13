defmodule Ircxd.ClientCapLifecycleTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits CAP NAK and ends capability negotiation" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * NAK :sasl"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

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
        caps: ["sasl"],
        notify: self()
      )

    assert_receive {:ircxd, {:cap_nak, ["sasl"]}}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "updates advertised capabilities on CAP NEW and DEL" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test CAP * NEW :server-time message-tags",
               ":irc.test CAP * DEL :message-tags"
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
        notify: self()
      )

    assert_receive {:ircxd, {:cap_new, %{"server-time" => true, "message-tags" => true}}},
                   1_000

    assert_receive {:ircxd, {:cap_del, ["message-tags"]}}, 1_000
  end
end
