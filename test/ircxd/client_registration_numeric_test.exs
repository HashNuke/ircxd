defmodule Ircxd.ClientRegistrationNumericTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed registration numeric events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome to the network",
               ":irc.test 002 nick :Your host is irc.test, running version ircd-1",
               ":irc.test 003 nick :This server was created today",
               ":irc.test 004 nick irc.test ircd-1 iosw biklmnopstv bklov"
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

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:welcome, %{nick: "nick", text: "Welcome to the network"}}}, 1_000

    assert_receive {:ircxd,
                    {:your_host, %{text: "Your host is irc.test, running version ircd-1"}}},
                   1_000

    assert_receive {:ircxd, {:server_created, %{text: "This server was created today"}}}, 1_000

    assert_receive {:ircxd,
                    {:server_info,
                     %{
                       server: "irc.test",
                       version: "ircd-1",
                       user_modes: "iosw",
                       channel_modes: "biklmnopstv",
                       params: ["bklov"]
                     }}},
                   1_000
  end

  test "responds to server PING with PONG" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome to the network",
               "PING :ping-token"
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

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:scripted_irc_line, "PONG ping-token"}, 1_000
  end

  test "retries registration nick on ERR_NICKNAMEINUSE" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 433 * nick :Nickname is already in use"]

           "NICK nick_", _state ->
             [":irc.test 001 nick_ :Welcome to the network"]

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

    assert_receive {:ircxd, {:nick_in_use, %{attempted: "nick", next: "nick_"}}}, 1_000
    assert_receive {:scripted_irc_line, "NICK nick_"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end
end
