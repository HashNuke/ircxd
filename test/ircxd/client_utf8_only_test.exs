defmodule Ircxd.ClientUTF8OnlyTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "rejects outbound non-UTF-8 parameters when UTF8ONLY is advertised" do
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
               ":irc.test 005 nick UTF8ONLY CHANTYPES=# :are supported by this server"
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
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:isupport, %{"UTF8ONLY" => true}}}, 1_000

    assert {:error, {:invalid_utf8, "PRIVMSG"}} =
             Ircxd.Client.privmsg(client, "#chan", <<0xFF>>)

    refute_receive {:scripted_irc_line, "PRIVMSG #chan \xFF"}, 250
  end
end
