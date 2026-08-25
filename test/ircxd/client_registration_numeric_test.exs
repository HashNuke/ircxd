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

    assert_receive {:ircxd,
                    {:nick_in_use,
                     %{
                       attempted: "nick",
                       next: "nick_",
                       reason: "Nickname is already in use",
                       message: %Ircxd.Message{command: "433"}
                     }}},
                   1_000

    assert_receive {:scripted_irc_line, "NICK nick_"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "does not retry a labeled post-registration nickname rejection" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :labeled-response batch"]

           "CAP REQ :labeled-response batch", _state ->
             [":irc.test CAP * ACK :labeled-response batch"]

           "CAP END", _state ->
             [":irc.test 001 mira :Welcome"]

           "@label=nick-1 NICK alice", _state ->
             ["@label=nick-1 :irc.test 433 mira alice :Nickname is already in use"]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "mira",
        username: "mira",
        realname: "Mira",
        caps: ["labeled-response", "batch"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "nick-1", "NICK", ["alice"])

    assert_receive {:ircxd,
                    {:nick_in_use,
                     %{
                       attempted: "alice",
                       next: nil,
                       label: "nick-1",
                       raw_message: %Ircxd.Message{command: "433"}
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{
                       label: "nick-1",
                       status: :failed,
                       reason: {:nick_in_use, %{attempted: "alice"}}
                     }}},
                   1_000

    refute_receive {:scripted_irc_line, "NICK alice_"}, 250
    assert :sys.get_state(client).current_nick == "mira"
  end
end
