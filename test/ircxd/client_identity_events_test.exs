defmodule Ircxd.ClientIdentityEventsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "includes IRCv3 account-tag metadata on messages" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :account-tag"]

           "CAP REQ account-tag", _state ->
             [":irc.test CAP * ACK :account-tag"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@account=alice :alice!a@example.test PRIVMSG #elixir :hello"
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
        caps: ["account-tag"],
        notify: self()
      )

    assert_receive {:ircxd, {:privmsg, %{nick: "alice", account: "alice", body: "hello"}}},
                   1_000
  end

  test "parses IRCv3 extended-join account and realname fields" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :extended-join"]

           "CAP REQ extended-join", _state ->
             [":irc.test CAP * ACK :extended-join"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":alice!a@example.test JOIN #elixir alice :Alice Example",
               ":guest!g@example.test JOIN #elixir * :Guest User"
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
        caps: ["extended-join"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:join,
                     %{
                       nick: "alice",
                       channel: "#elixir",
                       account: "alice",
                       realname: "Alice Example"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:join,
                     %{
                       nick: "guest",
                       channel: "#elixir",
                       account: nil,
                       realname: "Guest User"
                     }}},
                   1_000
  end
end
