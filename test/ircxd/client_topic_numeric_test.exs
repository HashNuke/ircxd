defmodule Ircxd.ClientTopicNumericTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed topic query numeric events" do
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
               ":irc.test 331 nick #empty :No topic is set",
               ":irc.test 332 nick #elixir :Elixir discussion",
               ":irc.test 333 nick #elixir alice 1760000000"
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

    assert_receive {:ircxd, {:topic_empty, %{channel: "#empty", text: "No topic is set"}}}, 1_000

    assert_receive {:ircxd, {:topic_reply, %{channel: "#elixir", topic: "Elixir discussion"}}},
                   1_000

    assert_receive {:ircxd,
                    {:topic_who_time,
                     %{channel: "#elixir", setter: "alice", set_at: "1760000000"}}},
                   1_000
  end
end
