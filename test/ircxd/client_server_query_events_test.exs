defmodule Ircxd.ClientServerQueryEventsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed Modern IRC server query numeric events" do
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
               ":irc.test 321 nick Channel :Users Name",
               ":irc.test 322 nick #elixir 42 :Elixir discussion",
               ":irc.test 323 nick :End of /LIST",
               ":irc.test 375 nick :- irc.test Message of the day -",
               ":irc.test 372 nick :- Be kind",
               ":irc.test 376 nick :End of /MOTD command",
               ":irc.test 256 nick irc.test :Administrative info",
               ":irc.test 257 nick :Somewhere",
               ":irc.test 258 nick :Operations",
               ":irc.test 259 nick :admin@example.test",
               ":irc.test 251 nick :There are 3 users and 1 services on 1 servers",
               ":irc.test 252 nick 1 :operator(s) online",
               ":irc.test 253 nick 2 :unknown connection(s)",
               ":irc.test 254 nick 4 :channels formed",
               ":irc.test 255 nick :I have 3 clients and 1 servers",
               ":irc.test 265 nick 3 10 :Current local users 3, max 10",
               ":irc.test 266 nick 3 10 :Current global users 3, max 10",
               ":irc.test 391 nick irc.test :Wed May 13 11:11:00 2026",
               ":irc.test 371 nick :Server info line",
               ":irc.test 374 nick :End of /INFO list",
               ":irc.test 364 nick *.test irc.test 0 :Main server",
               ":irc.test 365 nick *.test :End of /LINKS list",
               ":irc.test 302 nick :alice=+alice@example.test bob=-bob@example.test"
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

    assert_receive {:ircxd, {:list_start, %{params: ["nick", "Channel", "Users Name"]}}}, 1_000

    assert_receive {:ircxd,
                    {:list_entry,
                     %{channel: "#elixir", visible: "42", topic: "Elixir discussion"}}},
                   1_000

    assert_receive {:ircxd, {:list_end, %{params: ["nick", "End of /LIST"]}}}, 1_000
    assert_receive {:ircxd, {:motd_start, %{text: "- irc.test Message of the day -"}}}, 1_000
    assert_receive {:ircxd, {:motd, %{text: "- Be kind"}}}, 1_000
    assert_receive {:ircxd, {:motd_end, %{text: "End of /MOTD command"}}}, 1_000

    assert_receive {:ircxd, {:admin_start, %{server: "irc.test", text: "Administrative info"}}},
                   1_000

    assert_receive {:ircxd, {:admin_location, %{line: 1, text: "Somewhere"}}}, 1_000
    assert_receive {:ircxd, {:admin_location, %{line: 2, text: "Operations"}}}, 1_000
    assert_receive {:ircxd, {:admin_email, %{text: "admin@example.test"}}}, 1_000

    assert_receive {:ircxd,
                    {:lusers,
                     %{code: "251", text: "There are 3 users and 1 services on 1 servers"}}},
                   1_000

    assert_receive {:ircxd, {:lusers, %{code: "252", text: "operator(s) online"}}}, 1_000
    assert_receive {:ircxd, {:lusers, %{code: "253", text: "unknown connection(s)"}}}, 1_000
    assert_receive {:ircxd, {:lusers, %{code: "254", text: "channels formed"}}}, 1_000

    assert_receive {:ircxd, {:lusers, %{code: "255", text: "I have 3 clients and 1 servers"}}},
                   1_000

    assert_receive {:ircxd, {:lusers, %{code: "265", text: "Current local users 3, max 10"}}},
                   1_000

    assert_receive {:ircxd, {:lusers, %{code: "266", text: "Current global users 3, max 10"}}},
                   1_000

    assert_receive {:ircxd, {:time, %{server: "irc.test", time: "Wed May 13 11:11:00 2026"}}},
                   1_000

    assert_receive {:ircxd, {:info, %{text: "Server info line"}}}, 1_000
    assert_receive {:ircxd, {:info_end, %{text: "End of /INFO list"}}}, 1_000

    assert_receive {:ircxd,
                    {:links,
                     %{mask: "*.test", server: "irc.test", hopcount: "0", info: "Main server"}}},
                   1_000

    assert_receive {:ircxd, {:links_end, %{mask: "*.test", text: "End of /LINKS list"}}}, 1_000

    assert_receive {:ircxd,
                    {:userhost,
                     %{
                       replies: ["alice=+alice@example.test", "bob=-bob@example.test"],
                       entries: [
                         %{nick: "alice", away?: false, username: "alice", host: "example.test"},
                         %{nick: "bob", away?: true, username: "bob", host: "example.test"}
                       ]
                     }}},
                   1_000
  end
end
