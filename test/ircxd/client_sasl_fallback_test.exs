defmodule Ircxd.ClientSASLFallbackTest do
  use ExUnit.Case, async: false

  alias Ircxd.SASL
  alias Ircxd.ScriptedIrcServer

  test "falls back to the next configured SASL mechanism after failure" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl=EXTERNAL,PLAIN"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE EXTERNAL", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> external_payload, _state
           when external_payload == "bmljaw==" ->
             [":irc.test 904 nick :SASL authentication failed"]

           "AUTHENTICATE PLAIN", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> plain_payload, _state
           when plain_payload == "AG5pY2sAc2VjcmV0" ->
             [":irc.test 903 nick :SASL authentication successful"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

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
        sasl: [{:external, "nick"}, {:plain, "nick", "secret"}],
        notify: self()
      )

    assert_receive {:scripted_irc_line, "AUTHENTICATE EXTERNAL"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE " <> external_payload}, 1_000
    assert external_payload == SASL.external_payload("nick")

    assert_receive {:ircxd,
                    {:sasl_failure,
                     %{code: "904", policy: :retry, mechanism: :external, next_mechanism: :plain}}},
                   1_000

    assert_receive {:scripted_irc_line, "AUTHENTICATE PLAIN"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE " <> plain_payload}, 1_000
    assert plain_payload == SASL.plain_payload("nick", "secret")

    assert_receive {:ircxd, :sasl_success}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "skips configured SASL mechanisms that were not advertised by the server" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl=PLAIN"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE PLAIN", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> plain_payload, _state
           when plain_payload == "AG5pY2sAc2VjcmV0" ->
             [":irc.test 903 nick :SASL authentication successful"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

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
        sasl: [{:external, "nick"}, {:plain, "nick", "secret"}],
        notify: self()
      )

    refute_receive {:scripted_irc_line, "AUTHENTICATE EXTERNAL"}, 250
    assert_receive {:scripted_irc_line, "AUTHENTICATE PLAIN"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE " <> plain_payload}, 1_000
    assert plain_payload == SASL.plain_payload("nick", "secret")

    assert_receive {:ircxd, :sasl_success}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end
end
