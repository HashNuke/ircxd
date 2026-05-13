defmodule Ircxd.ClientExtendedMonitorTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "handles extended-monitor notifications for monitored users" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [
               ":irc.test CAP * LS :extended-monitor monitor away-notify account-notify chghost setname"
             ]

           "CAP REQ :extended-monitor monitor away-notify account-notify chghost setname",
           _state ->
             [
               ":irc.test CAP * ACK :extended-monitor monitor away-notify account-notify chghost setname"
             ]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "MONITOR + alice", _state ->
             [
               ":irc.test 730 nick :alice!a@example.test",
               ":alice!a@example.test ACCOUNT alice-account",
               ":alice!a@example.test AWAY :writing docs",
               ":alice!a@example.test CHGHOST newuser new.example.test",
               ":alice!newuser@new.example.test SETNAME :Alice Example"
             ]

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
        caps: [
          "extended-monitor",
          "monitor",
          "away-notify",
          "account-notify",
          "chghost",
          "setname"
        ],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.monitor_add(client, "alice")

    assert_receive {:ircxd, {:monitor, %{type: :online, targets: ["alice!a@example.test"]}}},
                   1_000

    assert_receive {:ircxd, {:account, %{nick: "alice", account: "alice-account"}}}, 1_000

    assert_receive {:ircxd, {:away, %{nick: "alice", away?: true, message: "writing docs"}}},
                   1_000

    assert_receive {:ircxd,
                    {:chghost, %{nick: "alice", username: "newuser", host: "new.example.test"}}},
                   1_000

    assert_receive {:ircxd, {:setname, %{nick: "alice", realname: "Alice Example"}}}, 1_000
  end
end
