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
               ":irc.test 010 nick irc2.test 6697 :Please use this server/port instead",
               ":irc.test 351 nick InspIRCd-3 irc.test :Boringville",
               ":irc.test 263 nick LIST :Server load is temporarily too heavy",
               ":irc.test 211 nick irc.test 12 34 56 78 90 :link info",
               ":irc.test 212 nick PRIVMSG 42 1 2 3",
               ":irc.test 213 nick C *@example.test server.test 6667 class",
               ":irc.test 215 nick I *@example.test * *@example.test 0 class",
               ":irc.test 216 nick K *@bad.example * :bad host",
               ":irc.test 241 nick L leaf.example.test * *",
               ":irc.test 242 nick :Server up 42 days 6:12:01",
               ":irc.test 243 nick O *@oper.example oper *",
               ":irc.test 244 nick H hub.example.test * *",
               ":irc.test 219 nick u :End of /STATS report",
               ":irc.test 704 nick LIST :Start of help",
               ":irc.test 705 nick LIST :Syntax: LIST [channels]",
               ":irc.test 706 nick LIST :End of help",
               ":irc.test 221 nick +i",
               ":irc.test 324 nick #elixir +nt",
               ":irc.test 329 nick #elixir 1760000000",
               ":irc.test 341 nick alice #elixir",
               ":irc.test 336 nick #elixir *!*@invited.example",
               ":irc.test 337 nick #elixir :End of channel invite list",
               ":irc.test 367 nick #elixir *!*@example.test setter 1760000001",
               ":irc.test 368 nick #elixir :End of channel ban list",
               ":irc.test 346 nick #elixir *!*@invite.example setter 1760000002",
               ":irc.test 347 nick #elixir :End of channel invite list",
               ":irc.test 348 nick #elixir *!*@except.example setter 1760000003",
               ":irc.test 349 nick #elixir :End of channel exception list",
               ":irc.test 303 nick :alice bob",
               ":irc.test 300 nick :Nothing to report",
               ":irc.test 301 nick alice :gone fishing",
               ":irc.test 305 nick :You are no longer marked as being away",
               ":irc.test 306 nick :You have been marked as being away",
               ":irc.test 234 nick NickServ services.test * 0 1 :Nickname service",
               ":irc.test 235 nick * 0 :End of service listing",
               ":irc.test 200 nick Link irc.test irc2.test :0 0",
               ":irc.test 201 nick Try. irc.test irc2.test",
               ":irc.test 202 nick H.S. irc.test irc2.test",
               ":irc.test 203 nick ???? irc.test irc2.test",
               ":irc.test 204 nick Oper nick[irc.test] :42 seconds",
               ":irc.test 205 nick User nick[irc.test] :0 seconds",
               ":irc.test 206 nick Serv 1 2S 3C irc.test!irc2.test :0 seconds",
               ":irc.test 207 nick Service NickServ 1 1S 0C :service info",
               ":irc.test 208 nick <newtype> name",
               ":irc.test 209 nick Class users :42",
               ":irc.test 210 nick irc.test 1S 2C :server info",
               ":irc.test 262 nick irc.test :End of TRACE",
               ":irc.test 392 nick :UserID Terminal Host",
               ":irc.test 393 nick :alice pts/0 example.test",
               ":irc.test 394 nick :End of users",
               ":irc.test 395 nick :USERS has been disabled",
               ":irc.test 381 nick :You are now an IRC operator",
               ":irc.test 382 nick ircd.conf :Rehashing",
               ":irc.test 670 nick :STARTTLS successful",
               ":irc.test 691 nick :STARTTLS failed"
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
                    {:bounce,
                     %{
                       hostname: "irc2.test",
                       port: "6697",
                       text: "Please use this server/port instead"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:version,
                     %{version: "InspIRCd-3", server: "irc.test", comments: "Boringville"}}},
                   1_000

    assert_receive {:ircxd,
                    {:try_again, %{command: "LIST", text: "Server load is temporarily too heavy"}}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_linkinfo,
                     %{params: ["irc.test", "12", "34", "56", "78", "90", "link info"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_command, %{command: "PRIVMSG", count: "42", params: ["1", "2", "3"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_line,
                     %{
                       code: "213",
                       params: ["C", "*@example.test", "server.test", "6667", "class"]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_line,
                     %{
                       code: "215",
                       params: ["I", "*@example.test", "*", "*@example.test", "0", "class"]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_line, %{code: "216", params: ["K", "*@bad.example", "*", "bad host"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_line, %{code: "241", params: ["L", "leaf.example.test", "*", "*"]}}},
                   1_000

    assert_receive {:ircxd, {:stats_uptime, %{text: "Server up 42 days 6:12:01"}}}, 1_000

    assert_receive {:ircxd,
                    {:stats_line, %{code: "243", params: ["O", "*@oper.example", "oper", "*"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:stats_line, %{code: "244", params: ["H", "hub.example.test", "*", "*"]}}},
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

    assert_receive {:ircxd, {:invite_list, %{channel: "#elixir", mask: "*!*@invited.example"}}},
                   1_000

    assert_receive {:ircxd,
                    {:invite_list_end, %{channel: "#elixir", text: "End of channel invite list"}}},
                   1_000

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

    assert_receive {:ircxd, {:ison, %{nicks: ["alice", "bob"]}}}, 1_000

    assert_receive {:ircxd,
                    {:none, %{params: ["nick", "Nothing to report"], text: "Nothing to report"}}},
                   1_000

    assert_receive {:ircxd, {:away_reply, %{nick: "alice", text: "gone fishing"}}}, 1_000

    assert_receive {:ircxd, {:unaway, %{text: "You are no longer marked as being away"}}},
                   1_000

    assert_receive {:ircxd, {:now_away, %{text: "You have been marked as being away"}}}, 1_000

    assert_receive {:ircxd,
                    {:servlist,
                     %{
                       name: "NickServ",
                       server: "services.test",
                       mask: "*",
                       type: "0",
                       hopcount: "1",
                       info: "Nickname service"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:servlist_end, %{mask: "*", type: "0", text: "End of service listing"}}},
                   1_000

    assert_receive {:ircxd,
                    {:trace, %{code: "200", params: ["Link", "irc.test", "irc2.test", "0 0"]}}},
                   1_000

    assert_receive {:ircxd, {:trace, %{code: "201", params: ["Try.", "irc.test", "irc2.test"]}}},
                   1_000

    assert_receive {:ircxd, {:trace, %{code: "202", params: ["H.S.", "irc.test", "irc2.test"]}}},
                   1_000

    assert_receive {:ircxd, {:trace, %{code: "203", params: ["????", "irc.test", "irc2.test"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:trace, %{code: "204", params: ["Oper", "nick[irc.test]", "42 seconds"]}}},
                   1_000

    assert_receive {:ircxd, {:trace, %{code: "205", text: "0 seconds"}}}, 1_000

    assert_receive {:ircxd,
                    {:trace,
                     %{
                       code: "206",
                       params: ["Serv", "1", "2S", "3C", "irc.test!irc2.test", "0 seconds"]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:trace,
                     %{
                       code: "207",
                       params: ["Service", "NickServ", "1", "1S", "0C", "service info"]
                     }}},
                   1_000

    assert_receive {:ircxd, {:trace, %{code: "208", params: ["<newtype>", "name"]}}},
                   1_000

    assert_receive {:ircxd, {:trace, %{code: "209", params: ["Class", "users", "42"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:trace, %{code: "210", params: ["irc.test", "1S", "2C", "server info"]}}},
                   1_000

    assert_receive {:ircxd, {:trace_end, %{target: "irc.test", text: "End of TRACE"}}}, 1_000
    assert_receive {:ircxd, {:users_start, %{text: "UserID Terminal Host"}}}, 1_000
    assert_receive {:ircxd, {:users, %{text: "alice pts/0 example.test"}}}, 1_000
    assert_receive {:ircxd, {:users_end, %{text: "End of users"}}}, 1_000
    assert_receive {:ircxd, {:users_disabled, %{text: "USERS has been disabled"}}}, 1_000
    assert_receive {:ircxd, {:youre_oper, %{text: "You are now an IRC operator"}}}, 1_000
    assert_receive {:ircxd, {:rehashing, %{config_file: "ircd.conf", text: "Rehashing"}}}, 1_000
    assert_receive {:ircxd, {:starttls, %{text: "STARTTLS successful"}}}, 1_000
    assert_receive {:ircxd, {:starttls_failed, %{text: "STARTTLS failed"}}}, 1_000
  end
end
