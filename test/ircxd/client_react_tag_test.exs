defmodule Ircxd.ClientReactTagTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends and receives draft react and unreact client tags" do
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
               "@+reply=parent-1;+draft/react=lol :alice!a@example.test TAGMSG #elixir",
               "@+reply=parent-1;+draft/unreact=lol :alice!a@example.test TAGMSG #elixir"
             ]

           "@+draft/react=lol;+reply=parent-1 TAGMSG #elixir", _state ->
             ["@+reply=parent-1;+draft/react=lol :nick!n@example.test TAGMSG #elixir"]

           "@+draft/unreact=lol;+reply=parent-1 TAGMSG #elixir", _state ->
             ["@+reply=parent-1;+draft/unreact=lol :nick!n@example.test TAGMSG #elixir"]

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
                    {:reaction,
                     %{
                       nick: "alice",
                       target: "#elixir",
                       action: :react,
                       reaction: "lol",
                       reply_to_msgid: "parent-1"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:reaction,
                     %{
                       nick: "alice",
                       target: "#elixir",
                       action: :unreact,
                       reaction: "lol",
                       reply_to_msgid: "parent-1"
                     }}},
                   1_000

    assert :ok = Ircxd.Client.react(client, "#elixir", "parent-1", "lol")

    assert_receive {:scripted_irc_line, "@+draft/react=lol;+reply=parent-1 TAGMSG #elixir"},
                   1_000

    assert :ok = Ircxd.Client.unreact(client, "#elixir", "parent-1", "lol")

    assert_receive {:scripted_irc_line, "@+draft/unreact=lol;+reply=parent-1 TAGMSG #elixir"},
                   1_000
  end

  test "rejects malformed reactions" do
    assert {:error, :missing_reply_msgid} = Ircxd.Client.react(self(), "#elixir", "", "lol")
    assert {:error, :missing_reaction} = Ircxd.Client.react(self(), "#elixir", "parent-1", "")
  end
end
