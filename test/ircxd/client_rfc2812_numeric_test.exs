defmodule Ircxd.ClientRFC2812NumericTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed RFC2812 summon and legacy error numeric events" do
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
               ":irc.test 342 nick alice :Summoning user to IRC",
               ":irc.test 413 nick $*.example :No toplevel domain specified",
               ":irc.test 423 nick irc.example.test :No administrative info available",
               ":irc.test 424 nick :File error doing read on motd",
               ":irc.test 437 nick #delayed :Nick/channel is temporarily unavailable",
               ":irc.test 444 nick alice :User not logged in",
               ":irc.test 445 nick :SUMMON has been disabled",
               ":irc.test 446 nick :USERS has been disabled",
               ":irc.test 463 nick :Your host isn't among the privileged",
               ":irc.test 466 nick :You will be banned soon",
               ":irc.test 467 nick #locked :Channel key already set",
               ":irc.test 477 nick #modeless :Channel doesn't support modes",
               ":irc.test 478 nick #elixir b :Channel list is full",
               ":irc.test 484 nick :Your connection is restricted!",
               ":irc.test 485 nick :You're not the original channel operator",
               ":irc.test 492 nick :No service host"
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

    assert_receive {:ircxd, {:summoning, %{user: "alice", text: "Summoning user to IRC"}}},
                   1_000

    assert_error("413", "$*.example", "No toplevel domain specified")
    assert_error("423", "irc.example.test", "No administrative info available")
    assert_error("424", nil, "File error doing read on motd")
    assert_error("437", "#delayed", "Nick/channel is temporarily unavailable")
    assert_error("444", "alice", "User not logged in")
    assert_error("445", nil, "SUMMON has been disabled")
    assert_error("446", nil, "USERS has been disabled")
    assert_error("463", nil, "Your host isn't among the privileged")
    assert_error("466", nil, "You will be banned soon")
    assert_error("467", "#locked", "Channel key already set")
    assert_error("477", "#modeless", "Channel doesn't support modes")
    assert_error("478", "#elixir", "Channel list is full")
    assert_error("484", nil, "Your connection is restricted!")
    assert_error("485", nil, "You're not the original channel operator")
    assert_error("492", nil, "No service host")
  end

  defp assert_error(code, target, reason) do
    assert_receive {:ircxd,
                    {:irc_error,
                     %{
                       code: ^code,
                       target: ^target,
                       reason: ^reason
                     }}},
                   1_000
  end
end
