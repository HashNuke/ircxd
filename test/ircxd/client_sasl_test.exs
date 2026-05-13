defmodule Ircxd.ClientSASLTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ircxd.SASL
  alias Ircxd.ScriptedIrcServer

  test "performs SASL PLAIN negotiation before ending CAP" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE PLAIN", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> _payload, _state ->
             [
               ":irc.test 900 nick nick!user@example.test nick :You are now logged in as nick",
               ":irc.test 903 nick :SASL authentication successful"
             ]

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
        sasl: {:plain, "nick", "secret"},
        notify: self()
      )

    expected_payload = SASL.plain_payload("nick", "secret")

    assert_receive {:scripted_irc_line, "CAP LS 302"}, 1_000
    assert_receive {:scripted_irc_line, "NICK nick"}, 1_000
    assert_receive {:scripted_irc_line, "USER nick 0 * Nick"}, 1_000
    assert_receive {:scripted_irc_line, "CAP REQ sasl"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE PLAIN"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE " <> ^expected_payload}, 1_000

    assert_receive {:ircxd,
                    {:logged_in,
                     %{
                       userhost: "nick!user@example.test",
                       account: "nick",
                       text: "You are now logged in as nick"
                     }}},
                   1_000

    assert_receive {:ircxd, :sasl_success}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "handles SASL nick-locked failure numeric" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE PLAIN", _state ->
             [":irc.test 902 nick :You must use a nick assigned to you"]

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
        sasl: {:plain, "nick", "secret"},
        notify: self()
      )

    assert_receive {:ircxd, {:sasl_failure, %{code: "902", policy: :continue}}}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "continues registration by default after SASL failure" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE PLAIN", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> _payload, _state ->
             [":irc.test 904 nick :SASL authentication failed"]

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
        sasl: {:plain, "nick", "bad-secret"},
        notify: self()
      )

    assert_receive {:ircxd, {:sasl_failure, %{code: "904", policy: :continue}}}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "can abort registration after SASL failure" do
    Process.flag(:trap_exit, true)

    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE PLAIN", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> _payload, _state ->
             [":irc.test 904 nick :SASL authentication failed"]

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
        sasl: {:plain, "nick", "bad-secret"},
        sasl_failure: :abort,
        notify: self()
      )

    capture_log(fn ->
      assert_receive {:ircxd, {:sasl_failure, %{code: "904", policy: :abort}}}, 1_000
      assert_receive {:scripted_irc_line, "QUIT :SASL authentication failed"}, 1_000

      assert_receive {:EXIT, ^client, :sasl_failure}, 1_000
    end)
  end

  test "emits SASL mechanism list replies without treating them as failures" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test 908 nick PLAIN,EXTERNAL,SCRAM-SHA-256 :are available SASL mechanisms"
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
        caps: ["sasl"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert_receive {:ircxd,
                    {:sasl_mechanisms, %{mechanisms: ["PLAIN", "EXTERNAL", "SCRAM-SHA-256"]}}},
                   1_000

    refute_receive {:ircxd, {:sasl_failure, %{code: "908"}}}, 250
  end
end
