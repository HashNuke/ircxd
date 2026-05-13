defmodule Ircxd.ClientSTSTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits STS policy events and does not request the sts capability" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sts=port=6697 message-tags"]

           "CAP REQ message-tags", _state ->
             [":irc.test CAP * ACK :message-tags"]

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
        caps: ["sts", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:sts_policy, %{host: "127.0.0.1", type: :upgrade, port: 6697, tls?: false}}},
                   1_000

    assert_receive {:scripted_irc_line, "CAP REQ message-tags"}, 1_000
    Process.sleep(250)
    refute Enum.any?(ScriptedIrcServer.lines(server), &String.contains?(&1, "CAP REQ sts"))
  end

  test "ignores CAP DEL sts" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sts=port=6697"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test CAP * DEL :sts",
               ":irc.test CAP * DEL :sts message-tags"
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

    assert_receive {:ircxd, {:sts_policy, %{type: :upgrade, port: 6697}}}, 1_000
    refute_receive {:ircxd, {:cap_del, []}}, 1_000
    refute_receive {:ircxd, {:cap_del, ["sts"]}}, 1_000
    assert_receive {:ircxd, {:cap_del, ["message-tags"]}}, 1_000
  end

  test "emits STS policy errors for invalid advertised policies" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sts=port=not-a-port"]

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
        notify: self()
      )

    assert_receive {:ircxd,
                    {:sts_policy_error,
                     %{
                       host: "127.0.0.1",
                       value: "port=not-a-port",
                       reason: :invalid_sts_policy
                     }}},
                   1_000
  end
end
