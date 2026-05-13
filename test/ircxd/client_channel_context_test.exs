defmodule Ircxd.ClientChannelContextTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends and receives draft channel-context tags on private messages" do
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
               "@+draft/channel-context=#elixir :bot!b@example.test NOTICE nick :private answer",
               "@+draft/channel-context=#elixir :bot!b@example.test PRIVMSG nick :private message"
             ]

           "@+draft/channel-context=#elixir NOTICE bot :private answer", _state ->
             [
               "@+draft/channel-context=#elixir :nick!n@example.test NOTICE bot :private answer"
             ]

           "@+draft/channel-context=#elixir PRIVMSG bot :private message", _state ->
             [
               "@+draft/channel-context=#elixir :nick!n@example.test PRIVMSG bot :private message"
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

    assert_receive {:ircxd,
                    {:notice,
                     %{
                       nick: "bot",
                       target: "nick",
                       body: "private answer",
                       channel_context: "#elixir"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:privmsg,
                     %{
                       nick: "bot",
                       target: "nick",
                       body: "private message",
                       channel_context: "#elixir"
                     }}},
                   1_000

    assert :ok = Ircxd.Client.context_notice(client, "bot", "#elixir", "private answer")

    assert_receive {:scripted_irc_line,
                    "@+draft/channel-context=#elixir NOTICE bot :private answer"},
                   1_000

    assert :ok = Ircxd.Client.context_privmsg(client, "bot", "#elixir", "private message")

    assert_receive {:scripted_irc_line,
                    "@+draft/channel-context=#elixir PRIVMSG bot :private message"},
                   1_000
  end

  test "rejects missing channel context" do
    assert {:error, :missing_channel_context} =
             Ircxd.Client.context_privmsg(self(), "bot", "", "private message")
  end
end
