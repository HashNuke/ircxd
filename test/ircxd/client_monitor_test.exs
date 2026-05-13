defmodule Ircxd.ClientMonitorTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends MONITOR commands and emits monitor numeric events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "MONITOR + alice,bob", _state ->
             [
               ":irc.test 730 nick :alice!a@example.test",
               ":irc.test 731 nick :bob"
             ]

           "MONITOR L", _state ->
             [
               ":irc.test 732 nick :alice,bob",
               ":irc.test 733 nick :End of MONITOR list"
             ]

           "MONITOR S", _state ->
             [":irc.test 734 nick 1 alice,bob :Monitor list is full"]

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

    assert :ok = Ircxd.Client.monitor_add(client, ["alice", "bob"])
    assert_receive {:scripted_irc_line, "MONITOR + alice,bob"}, 1_000

    assert_receive {:ircxd, {:monitor, %{type: :online, targets: ["alice!a@example.test"]}}},
                   1_000

    assert_receive {:ircxd, {:monitor, %{type: :offline, targets: ["bob"]}}}, 1_000

    assert :ok = Ircxd.Client.monitor_list(client)
    assert_receive {:scripted_irc_line, "MONITOR L"}, 1_000
    assert_receive {:ircxd, {:monitor, %{type: :list, targets: ["alice", "bob"]}}}, 1_000
    assert_receive {:ircxd, {:monitor, %{type: :list_end}}}, 1_000

    assert :ok = Ircxd.Client.monitor_status(client)
    assert_receive {:scripted_irc_line, "MONITOR S"}, 1_000

    assert_receive {:ircxd,
                    {:monitor,
                     %{
                       type: :list_full,
                       limit: 1,
                       targets: ["alice", "bob"],
                       description: "Monitor list is full"
                     }}},
                   1_000

    assert :ok = Ircxd.Client.monitor_remove(client, "alice")
    assert_receive {:scripted_irc_line, "MONITOR - alice"}, 1_000

    assert :ok = Ircxd.Client.monitor_clear(client)
    assert_receive {:scripted_irc_line, "MONITOR C"}, 1_000
  end
end
