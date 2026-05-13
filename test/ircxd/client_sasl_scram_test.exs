defmodule Ircxd.ClientSASLScramTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ircxd.SASL
  alias Ircxd.ScriptedIrcServer

  test "performs SASL SCRAM-SHA-256 negotiation before ending CAP" do
    nonce = "rOprNGfwEbeRWgbNEkqO"

    client_first = SASL.scram_sha256_client_first("user", nonce)

    server_first =
      "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," <>
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

    {:ok, client_final} =
      SASL.scram_sha256_client_final(client_first.bare, server_first, "pencil")

    client_first_payload = client_first.payload
    client_final_payload = client_final.payload
    server_first_payload = Base.encode64(server_first)
    server_final_payload = Base.encode64("v=#{client_final.server_signature}")

    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl=SCRAM-SHA-256,PLAIN"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE SCRAM-SHA-256", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> ^client_first_payload, _state ->
             ["AUTHENTICATE #{server_first_payload}"]

           "AUTHENTICATE " <> ^client_final_payload, _state ->
             [
               "AUTHENTICATE #{server_final_payload}",
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
        sasl: {:scram_sha_256, "user", "pencil", nonce: nonce},
        notify: self()
      )

    assert_receive {:scripted_irc_line, "CAP REQ sasl"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE SCRAM-SHA-256"}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE " <> first_payload}, 1_000
    assert first_payload == client_first_payload
    assert_receive {:scripted_irc_line, "AUTHENTICATE " <> final_payload}, 1_000
    assert final_payload == client_final_payload
    assert_receive {:ircxd, :sasl_success}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "rejects SASL SCRAM-SHA-256 success without a valid server-final signature" do
    Process.flag(:trap_exit, true)

    nonce = "rOprNGfwEbeRWgbNEkqO"
    client_first = SASL.scram_sha256_client_first("user", nonce)

    server_first =
      "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," <>
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

    {:ok, client_final} =
      SASL.scram_sha256_client_final(client_first.bare, server_first, "pencil")

    client_first_payload = client_first.payload
    client_final_payload = client_final.payload
    server_first_payload = Base.encode64(server_first)
    invalid_server_final_payload = Base.encode64("v=invalid")

    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl=SCRAM-SHA-256"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE SCRAM-SHA-256", _state ->
             ["AUTHENTICATE +"]

           "AUTHENTICATE " <> ^client_first_payload, _state ->
             ["AUTHENTICATE #{server_first_payload}"]

           "AUTHENTICATE " <> ^client_final_payload, _state ->
             [
               "AUTHENTICATE #{invalid_server_final_payload}",
               ":irc.test 903 nick :SASL authentication successful"
             ]

           _line, _state ->
             []
         end}
      )

    capture_log(fn ->
      {:ok, client} =
        Ircxd.start_link(
          host: "127.0.0.1",
          port: ScriptedIrcServer.port(server),
          nick: "nick",
          username: "nick",
          realname: "Nick",
          sasl: {:scram_sha_256, "user", "pencil", nonce: nonce},
          notify: self()
        )

      assert_receive {:ircxd, {:sasl_scram_error, %{reason: :invalid_server_signature}}}, 1_000

      assert_receive {:ircxd, {:sasl_scram_error, %{reason: :missing_verified_server_final}}},
                     1_000

      assert_receive {:scripted_irc_line, "QUIT :SASL SCRAM verification failed"}, 1_000
      assert_receive {:EXIT, ^client, :sasl_failure}, 1_000
      refute_receive {:ircxd, :sasl_success}, 250
    end)
  end
end
