defmodule Ircxd.ClientRemoteISupportTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits remote ISUPPORT without replacing active server ISUPPORT state" do
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
               ":irc.test 005 nick BOT=b CHANTYPES=# :are supported by this server",
               ":irc.test 105 nick BOT=x CHANTYPES=& :remote server support"
             ]

           "MODE nick +b", _state ->
             [":nick!user@host MODE nick +b"]

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
    assert_receive {:ircxd, {:isupport, %{"BOT" => "b", "CHANTYPES" => "#"}}}, 1_000
    assert_receive {:ircxd, {:remote_isupport, %{"BOT" => "x", "CHANTYPES" => "&"}}}, 1_000

    assert :ok = Ircxd.Client.bot_mode(client, true)
    assert_receive {:scripted_irc_line, "MODE nick +b"}, 1_000
  end
end
