defmodule Ircxd.ClientErrorNumericTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed Modern IRC error numeric events" do
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
               ":irc.test 400 nick WHO :Unknown error",
               ":irc.test 401 nick missing :No such nick/channel",
               ":irc.test 403 nick #missing :No such channel",
               ":irc.test 404 nick #chan :Cannot send to channel",
               ":irc.test 407 nick #a,#b :Too many targets",
               ":irc.test 408 nick ServiceName :No such service",
               ":irc.test 409 nick :No origin specified",
               ":irc.test 414 nick *.example.* :Wildcard in toplevel domain",
               ":irc.test 415 nick bad*mask :Bad server/host mask",
               ":irc.test 421 nick BOGUS :Unknown command",
               ":irc.test 461 nick WHO :Not enough parameters",
               ":irc.test 471 nick #full :Cannot join channel (+l)",
               ":irc.test 473 nick #invite :Cannot join channel (+i)",
               ":irc.test 474 nick #banned :Cannot join channel (+b)",
               ":irc.test 475 nick #keyed :Cannot join channel (+k)",
               ":irc.test 476 nick #bad :Bad channel mask",
               ":irc.test 481 nick :Permission Denied- You're not an IRC operator",
               ":irc.test 482 nick #chan :You're not channel operator",
               ":irc.test 524 nick * :Help not found",
               ":irc.test 696 nick #chan k bad-key :Invalid mode parameter"
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

    assert_error("401", "missing", "No such nick/channel")
    assert_error("400", "WHO", "Unknown error")
    assert_error("403", "#missing", "No such channel")
    assert_error("404", "#chan", "Cannot send to channel")
    assert_error("407", "#a,#b", "Too many targets")
    assert_error("408", "ServiceName", "No such service")
    assert_error("409", nil, "No origin specified")
    assert_error("414", "*.example.*", "Wildcard in toplevel domain")
    assert_error("415", "bad*mask", "Bad server/host mask")
    assert_error("421", "BOGUS", "Unknown command")
    assert_error("461", "WHO", "Not enough parameters")
    assert_error("471", "#full", "Cannot join channel (+l)")
    assert_error("473", "#invite", "Cannot join channel (+i)")
    assert_error("474", "#banned", "Cannot join channel (+b)")
    assert_error("475", "#keyed", "Cannot join channel (+k)")
    assert_error("476", "#bad", "Bad channel mask")
    assert_error("481", nil, "Permission Denied- You're not an IRC operator")
    assert_error("482", "#chan", "You're not channel operator")
    assert_error("524", "*", "Help not found")
    assert_error("696", "#chan", "Invalid mode parameter")
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
