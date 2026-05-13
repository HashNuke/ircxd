defmodule Ircxd.ClientNetBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "aggregates stable IRCv3 netsplit and netjoin batches" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch"]

           "CAP REQ batch", _state ->
             [":irc.test CAP * ACK :batch"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test BATCH +split1 netsplit irc.hub other.host",
               "@batch=split1 :alice!a@example.test QUIT :irc.hub other.host",
               "@batch=split1 :bob!b@example.test QUIT :irc.hub other.host",
               ":irc.test BATCH -split1",
               ":irc.test BATCH +join1 netjoin irc.hub other.host",
               "@batch=join1 :alice!a@example.test JOIN #elixir",
               "@batch=join1 :bob!b@example.test JOIN #elixir",
               ":irc.test BATCH -join1"
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
        caps: ["batch"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:netsplit,
                     %{
                       ref: "split1",
                       from_server: "irc.hub",
                       to_server: "other.host",
                       events: [
                         {:quit, %{nick: "alice", reason: "irc.hub other.host"}},
                         {:quit, %{nick: "bob", reason: "irc.hub other.host"}}
                       ]
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:netjoin,
                     %{
                       ref: "join1",
                       from_server: "irc.hub",
                       to_server: "other.host",
                       events: [
                         {:join, %{nick: "alice", channel: "#elixir"}},
                         {:join, %{nick: "bob", channel: "#elixir"}}
                       ]
                     }}},
                   1_000
  end
end
