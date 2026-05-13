defmodule Ircxd.ClientDCCTest do
  use ExUnit.Case, async: false

  alias Ircxd.CTCP
  alias Ircxd.DCC
  alias Ircxd.ScriptedIrcServer

  test "exposes parsed DCC payloads on CTCP PRIVMSG and NOTICE events" do
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
               ":alice!a@example.test PRIVMSG nick :\x01DCC SEND \"file name.txt\" 2130706433 9000 12345\x01",
               ":alice!a@example.test NOTICE nick :\x01DCC CHAT chat 2001:db8::1 0\x01",
               ":alice!a@example.test PRIVMSG nick :\x01DCC SEND file.txt 2130706433 bad-port\x01"
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

    assert_receive {:ircxd,
                    {:privmsg,
                     %{
                       nick: "alice",
                       ctcp: {:ok, %CTCP{command: "DCC"}},
                       dcc: %DCC{
                         type: "SEND",
                         argument: "file name.txt",
                         host: "127.0.0.1",
                         port: 9000,
                         reverse?: false,
                         extra: ["12345"]
                       }
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:notice,
                     %{
                       nick: "alice",
                       dcc: %DCC{
                         type: "CHAT",
                         argument: "chat",
                         host: "2001:db8::1",
                         port: 0,
                         reverse?: true
                       }
                     }}},
                   1_000

    assert_receive {:ircxd, {:privmsg, %{nick: "alice", dcc: {:error, :invalid_port}}}}, 1_000
  end
end
