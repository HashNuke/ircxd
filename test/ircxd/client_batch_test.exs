defmodule Ircxd.ClientBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "tracks IRCv3 batches and marks batched events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch server-time"]

           "CAP REQ :batch server-time", _state ->
             [":irc.test CAP * ACK :batch server-time"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "BATCH +hist1 chathistory #elixir",
               "@batch=hist1;time=2026-05-13T06:00:00.000Z :alice!a@example.test PRIVMSG #elixir :before you joined",
               "BATCH -hist1"
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
        caps: ["batch", "server-time"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:batch_start, %{ref: "hist1", type: "chathistory", params: ["#elixir"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:privmsg,
                     %{
                       nick: "alice",
                       target: "#elixir",
                       body: "before you joined",
                       batch: "hist1"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:batched,
                     %{
                       ref: "hist1",
                       batch: %{type: "chathistory", params: ["#elixir"]},
                       event: {:privmsg, %{body: "before you joined"}}
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:batch_end,
                     %{ref: "hist1", batch: %{type: "chathistory", params: ["#elixir"]}}}},
                   1_000
  end

  test "emits batch errors for malformed batch messages" do
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
               "BATCH +broken"
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

    assert_receive {:ircxd, {:batch_error, %{reason: :missing_type, message: message}}}, 1_000
    assert message.command == "BATCH"
    assert message.params == ["+broken"]
  end

  test "emits batch errors for unknown batch endings" do
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
               "BATCH -missing"
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

    assert_receive {:ircxd, {:batch_error, %{reason: :unknown_batch, ref: "missing"}}}, 1_000
    refute_receive {:ircxd, {:batch_end, %{ref: "missing"}}}, 250
  end
end
