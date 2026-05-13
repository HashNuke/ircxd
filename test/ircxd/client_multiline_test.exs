defmodule Ircxd.ClientMultilineTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "combines received draft/multiline batches and sends multiline batches" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [
               ":irc.test CAP * LS :batch draft/multiline=multiline,max-bytes=4096,max-lines=20 message-tags"
             ]

           "CAP REQ :batch draft/multiline message-tags", _state ->
             [":irc.test CAP * ACK :batch draft/multiline message-tags"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":alice!a@example.test BATCH +multi1 draft/multiline #elixir",
               "@batch=multi1 :alice!a@example.test PRIVMSG #elixir :hello",
               "@batch=multi1 :alice!a@example.test PRIVMSG #elixir :",
               "@batch=multi1 :alice!a@example.test PRIVMSG #elixir :how is ",
               "@batch=multi1;draft/multiline-concat :alice!a@example.test PRIVMSG #elixir :everyone?",
               "BATCH -multi1"
             ]

           "BATCH +ircxd-1 draft/multiline #elixir", _state ->
             []

           "@batch=ircxd-1 PRIVMSG #elixir hello", _state ->
             []

           "@batch=ircxd-1 PRIVMSG #elixir :", _state ->
             []

           "@batch=ircxd-1 PRIVMSG #elixir :how is everyone?", _state ->
             []

           "BATCH -ircxd-1", _state ->
             []

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
        caps: ["batch", "draft/multiline", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:multiline,
                     %{
                       ref: "multi1",
                       target: "#elixir",
                       command: "PRIVMSG",
                       body: "hello\n\nhow is everyone?",
                       nick: "alice"
                     }}},
                   1_000

    assert :ok =
             Ircxd.Client.multiline_privmsg(client, "#elixir", "hello\n\nhow is everyone?",
               ref: "ircxd-1"
             )

    assert_receive {:scripted_irc_line, "BATCH +ircxd-1 draft/multiline #elixir"}, 1_000
    assert_receive {:scripted_irc_line, "@batch=ircxd-1 PRIVMSG #elixir hello"}, 1_000
    assert_receive {:scripted_irc_line, "@batch=ircxd-1 PRIVMSG #elixir :"}, 1_000
    assert_receive {:scripted_irc_line, "@batch=ircxd-1 PRIVMSG #elixir :how is everyone?"}, 1_000
    assert_receive {:scripted_irc_line, "BATCH -ircxd-1"}, 1_000
  end
end
