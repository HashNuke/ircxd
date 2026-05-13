defmodule Ircxd.ClientUserhostNamesTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits all multi-prefix ranks from RPL_NAMREPLY" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :multi-prefix"]

           "CAP REQ multi-prefix", _state ->
             [":irc.test CAP * ACK :multi-prefix"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test 353 nick = #elixir :~&@%+alice +bob plain"
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
        caps: ["multi-prefix"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:names,
                     %{
                       channel: "#elixir",
                       names: [
                         %{nick: "alice", prefixes: ["~", "&", "@", "%", "+"]},
                         %{nick: "bob", prefixes: ["+"]},
                         %{nick: "plain", prefixes: []}
                       ]
                     }}},
                   1_000
  end

  test "emits parsed userhost-in-names entries from RPL_NAMREPLY" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :userhost-in-names"]

           "CAP REQ userhost-in-names", _state ->
             [":irc.test CAP * ACK :userhost-in-names"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test 353 nick = #elixir :@alice!a@example.test bob!b@example.test"
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
        caps: ["userhost-in-names"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:names,
                     %{
                       channel: "#elixir",
                       names: [
                         %{nick: "alice", prefixes: ["@"], user: "a", host: "example.test"},
                         %{nick: "bob", prefixes: [], user: "b", host: "example.test"}
                       ]
                     }}},
                   1_000
  end
end
