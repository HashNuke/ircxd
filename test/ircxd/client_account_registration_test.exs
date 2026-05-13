defmodule Ircxd.ClientAccountRegistrationTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends REGISTER and VERIFY commands and emits account registration events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/account-registration=email-required,custom-account-name"]

           "CAP REQ draft/account-registration", _state ->
             [":irc.test CAP * ACK :draft/account-registration"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "REGISTER test tester@example.org hunter2", _state ->
             [
               "REGISTER VERIFICATION_REQUIRED test :Account created, pending verification"
             ]

           "VERIFY test 39gvcdg4myvnmdcfhvd6exsv4n", _state ->
             ["VERIFY SUCCESS test :Account successfully registered"]

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
        caps: ["draft/account-registration"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.register_account(client, "test", "tester@example.org", "hunter2")
    assert_receive {:scripted_irc_line, "REGISTER test tester@example.org hunter2"}, 1_000

    assert_receive {:ircxd,
                    {:account_registration,
                     %{
                       command: "REGISTER",
                       status: :verification_required,
                       account: "test",
                       message: "Account created, pending verification"
                     }}},
                   1_000

    assert :ok = Ircxd.Client.verify_account(client, "test", "39gvcdg4myvnmdcfhvd6exsv4n")
    assert_receive {:scripted_irc_line, "VERIFY test 39gvcdg4myvnmdcfhvd6exsv4n"}, 1_000

    assert_receive {:ircxd,
                    {:account_registration,
                     %{
                       command: "VERIFY",
                       status: :success,
                       account: "test",
                       message: "Account successfully registered"
                     }}},
                   1_000
  end

  test "rejects REGISTER before draft/account-registration is negotiated" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

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
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert {:error, {:capability_not_enabled, "draft/account-registration"}} =
             Ircxd.Client.register_account(client, "*", "*", "hunter2")

    refute_receive {:scripted_irc_line, "REGISTER * * hunter2"}, 250
  end

  test "rejects REGISTER after draft/account-registration is deleted" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/account-registration"]

           "CAP REQ draft/account-registration", _state ->
             [":irc.test CAP * ACK :draft/account-registration"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome", ":irc.test CAP * DEL :draft/account-registration"]

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
        caps: ["draft/account-registration"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_del, ["draft/account-registration"]}}, 1_000

    assert {:error, {:capability_not_enabled, "draft/account-registration"}} =
             Ircxd.Client.register_account(client, "test", "tester@example.org", "hunter2")

    refute_receive {:scripted_irc_line, "REGISTER test tester@example.org hunter2"}, 250
  end
end
