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
               ":irc.test 402 nick irc.missing.test :No such server",
               ":irc.test 403 nick #missing :No such channel",
               ":irc.test 404 nick #chan :Cannot send to channel",
               ":irc.test 405 nick #too-many :You have joined too many channels",
               ":irc.test 406 nick gone :There was no such nickname",
               ":irc.test 407 nick #a,#b :Too many targets",
               ":irc.test 408 nick ServiceName :No such service",
               ":irc.test 409 nick :No origin specified",
               ":irc.test 411 nick :No recipient given",
               ":irc.test 412 nick :No text to send",
               ":irc.test 414 nick *.example.* :Wildcard in toplevel domain",
               ":irc.test 415 nick bad*mask :Bad server/host mask",
               ":irc.test 417 nick :Input line was too long",
               ":irc.test 421 nick BOGUS :Unknown command",
               ":irc.test 431 nick :No nickname given",
               ":irc.test 432 nick bad*nick :Erroneous nickname",
               ":irc.test 436 nick nick :Nickname collision",
               ":irc.test 441 nick alice #chan :They aren't on that channel",
               ":irc.test 442 nick #chan :You're not on that channel",
               ":irc.test 443 nick alice #chan :is already on channel",
               ":irc.test 451 nick :You have not registered",
               ":irc.test 461 nick WHO :Not enough parameters",
               ":irc.test 462 nick :You may not reregister",
               ":irc.test 464 nick :Password incorrect",
               ":irc.test 465 nick :You are banned from this server",
               ":irc.test 471 nick #full :Cannot join channel (+l)",
               ":irc.test 472 nick z :is unknown mode char to me",
               ":irc.test 473 nick #invite :Cannot join channel (+i)",
               ":irc.test 474 nick #banned :Cannot join channel (+b)",
               ":irc.test 475 nick #keyed :Cannot join channel (+k)",
               ":irc.test 476 nick #bad :Bad channel mask",
               ":irc.test 481 nick :Permission Denied- You're not an IRC operator",
               ":irc.test 482 nick #chan :You're not channel operator",
               ":irc.test 483 nick :You can't kill a server",
               ":irc.test 491 nick :No O-lines for your host",
               ":irc.test 501 nick :Unknown MODE flag",
               ":irc.test 502 nick :Cannot change mode for other users",
               ":irc.test 524 nick * :Help not found",
               ":irc.test 525 nick #chan :Key is not well-formed",
               ":irc.test 696 nick #chan k bad-key :Invalid mode parameter",
               ":irc.test 723 nick kill:remote :Insufficient oper privileges"
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
    assert_error("402", "irc.missing.test", "No such server")
    assert_error("403", "#missing", "No such channel")
    assert_error("404", "#chan", "Cannot send to channel")
    assert_error("405", "#too-many", "You have joined too many channels")
    assert_error("406", "gone", "There was no such nickname")
    assert_error("407", "#a,#b", "Too many targets")
    assert_error("408", "ServiceName", "No such service")
    assert_error("409", nil, "No origin specified")
    assert_error("411", nil, "No recipient given")
    assert_error("412", nil, "No text to send")
    assert_error("414", "*.example.*", "Wildcard in toplevel domain")
    assert_error("415", "bad*mask", "Bad server/host mask")
    assert_error("417", nil, "Input line was too long")
    assert_error("421", "BOGUS", "Unknown command")
    assert_error("431", nil, "No nickname given")
    assert_error("432", "bad*nick", "Erroneous nickname")
    assert_error("436", "nick", "Nickname collision")
    assert_error("441", "alice", "They aren't on that channel")
    assert_error("442", "#chan", "You're not on that channel")
    assert_error("443", "alice", "is already on channel")
    assert_error("451", nil, "You have not registered")
    assert_error("461", "WHO", "Not enough parameters")
    assert_error("462", nil, "You may not reregister")
    assert_error("464", nil, "Password incorrect")
    assert_error("465", nil, "You are banned from this server")
    assert_error("471", "#full", "Cannot join channel (+l)")
    assert_error("472", "z", "is unknown mode char to me")
    assert_error("473", "#invite", "Cannot join channel (+i)")
    assert_error("474", "#banned", "Cannot join channel (+b)")
    assert_error("475", "#keyed", "Cannot join channel (+k)")
    assert_error("476", "#bad", "Bad channel mask")
    assert_error("481", nil, "Permission Denied- You're not an IRC operator")
    assert_error("482", "#chan", "You're not channel operator")
    assert_error("483", nil, "You can't kill a server")
    assert_error("491", nil, "No O-lines for your host")
    assert_error("501", nil, "Unknown MODE flag")
    assert_error("502", nil, "Cannot change mode for other users")
    assert_error("524", "*", "Help not found")
    assert_error("525", "#chan", "Key is not well-formed")
    assert_error("696", "#chan", "Invalid mode parameter")
    assert_error("723", "kill:remote", "Insufficient oper privileges")
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
