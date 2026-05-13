defmodule Ircxd.ClientModernNumericEventsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed Modern IRC query and channel numeric events" do
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
               ":irc.test 351 nick InspIRCd-3 irc.test :Boringville",
               ":irc.test 212 nick PRIVMSG 42 1 2 3",
               ":irc.test 219 nick u :End of /STATS report",
               ":irc.test 704 nick LIST :Start of help",
               ":irc.test 705 nick LIST :Syntax: LIST [channels]",
               ":irc.test 706 nick LIST :End of help",
               ":irc.test 221 nick +i",
               ":irc.test 324 nick #elixir +nt",
               ":irc.test 329 nick #elixir 1760000000",
               ":irc.test 341 nick alice #elixir",
               ":irc.test 367 nick #elixir *!*@example.test setter 1760000001",
               ":irc.test 368 nick #elixir :End of channel ban list",
               ":irc.test 346 nick #elixir *!*@invite.example setter 1760000002",
               ":irc.test 347 nick #elixir :End of channel invite list",
               ":irc.test 348 nick #elixir *!*@except.example setter 1760000003",
               ":irc.test 349 nick #elixir :End of channel exception list"
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

    assert_receive {:ircxd,
                    {:version,
                     %{version: "InspIRCd-3", server: "irc.test", comments: "Boringville"}}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_command, %{command: "PRIVMSG", count: "42", params: ["1", "2", "3"]}}},
                   1_000

    assert_receive {:ircxd, {:stats_end, %{query: "u", text: "End of /STATS report"}}}, 1_000
    assert_receive {:ircxd, {:help_start, %{subject: "LIST", text: "Start of help"}}}, 1_000
    assert_receive {:ircxd, {:help, %{subject: "LIST", text: "Syntax: LIST [channels]"}}}, 1_000
    assert_receive {:ircxd, {:help_end, %{subject: "LIST", text: "End of help"}}}, 1_000
    assert_receive {:ircxd, {:user_mode, %{modes: "+i"}}}, 1_000

    assert_receive {:ircxd, {:channel_mode, %{channel: "#elixir", modes: "+nt", params: []}}},
                   1_000

    assert_receive {:ircxd, {:channel_created, %{channel: "#elixir", created_at: "1760000000"}}},
                   1_000

    assert_receive {:ircxd, {:inviting, %{nick: "alice", channel: "#elixir"}}}, 1_000

    assert_receive {:ircxd,
                    {:ban_list,
                     %{
                       channel: "#elixir",
                       mask: "*!*@example.test",
                       params: ["setter", "1760000001"]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:ban_list_end, %{channel: "#elixir", text: "End of channel ban list"}}},
                   1_000

    assert_receive {:ircxd,
                    {:invite_exception_list,
                     %{
                       channel: "#elixir",
                       mask: "*!*@invite.example",
                       params: ["setter", "1760000002"]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:invite_exception_list_end,
                     %{channel: "#elixir", text: "End of channel invite list"}}},
                   1_000

    assert_receive {:ircxd,
                    {:exception_list,
                     %{
                       channel: "#elixir",
                       mask: "*!*@except.example",
                       params: ["setter", "1760000003"]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:exception_list_end,
                     %{channel: "#elixir", text: "End of channel exception list"}}},
                   1_000
  end
end
