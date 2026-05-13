defmodule Ircxd.ClientPresenceEventsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits IRCv3 account-notify, away-notify, and chghost events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :account-notify away-notify chghost"]

           "CAP REQ :account-notify away-notify chghost", _state ->
             [":irc.test CAP * ACK :account-notify away-notify chghost"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":alice!old@example.test ACCOUNT alice-account",
               ":guest!g@example.test ACCOUNT *",
               ":alice!old@example.test AWAY :writing tests",
               ":alice!old@example.test AWAY",
               ":alice!old@example.test CHGHOST newuser new.example.test"
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
        caps: ["account-notify", "away-notify", "chghost"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:account, %{nick: "alice", account: "alice-account", logged_in?: true}}},
                   1_000

    assert_receive {:ircxd, {:account, %{nick: "guest", account: nil, logged_in?: false}}},
                   1_000

    assert_receive {:ircxd, {:away, %{nick: "alice", away?: true, message: "writing tests"}}},
                   1_000

    assert_receive {:ircxd, {:away, %{nick: "alice", away?: false, message: nil}}},
                   1_000

    assert_receive {:ircxd,
                    {:chghost, %{nick: "alice", username: "newuser", host: "new.example.test"}}},
                   1_000
  end
end
