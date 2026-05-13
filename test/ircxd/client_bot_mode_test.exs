defmodule Ircxd.ClientBotModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "uses BOT ISUPPORT for bot mode and parses bot indicators" do
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
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test 005 nick BOT=b CHANTYPES=# :are supported by this server",
               "@bot :robodan!bot@example.test PRIVMSG #bots :beep"
             ]

           "MODE nick +b", _state ->
             [":nick!user@host MODE nick +b"]

           "WHO robodan", _state ->
             [
               ":irc.test 352 nick * bot example.test irc.test robodan Hb :0 Robot",
               ":irc.test 315 nick robodan :End of WHO list"
             ]

           "WHOIS robodan", _state ->
             [
               ":irc.test 335 nick robodan :is a Bot on IRCv3",
               ":irc.test 318 nick robodan :End of /WHOIS list"
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
        caps: ["message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:isupport, %{"BOT" => "b"}}}, 1_000
    assert_receive {:ircxd, {:privmsg, %{nick: "robodan", bot?: true, body: "beep"}}}, 1_000

    assert :ok = Ircxd.Client.bot_mode(client, true)
    assert_receive {:scripted_irc_line, "MODE nick +b"}, 1_000

    assert :ok = Ircxd.Client.who(client, "robodan")
    assert_receive {:ircxd, {:who_reply, %{nick: "robodan", bot?: true}}}, 1_000

    assert :ok = Ircxd.Client.whois(client, "robodan")

    assert_receive {:ircxd,
                    {:whois_bot, %{nick: "robodan", message: "is a Bot on IRCv3", bot?: true}}},
                   1_000
  end

  test "rejects invalid BOT ISUPPORT values" do
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
               ":irc.test 005 nick BOT=bot CHANTYPES=# :are supported by this server"
             ]

           "WHO robodan", _state ->
             [
               ":irc.test 352 nick * bot example.test irc.test robodan Hb :0 Robot",
               ":irc.test 315 nick robodan :End of WHO list"
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
    assert_receive {:ircxd, {:isupport, %{"BOT" => "bot"}}}, 1_000

    assert {:error, :bot_mode_not_supported} = Ircxd.Client.bot_mode(client, true)

    assert :ok = Ircxd.Client.who(client, "robodan")
    assert_receive {:ircxd, {:who_reply, %{nick: "robodan", bot?: false}}}, 1_000
  end
end
