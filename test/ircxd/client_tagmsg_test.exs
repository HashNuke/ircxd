defmodule Ircxd.ClientTagmsgTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends and receives IRCv3 TAGMSG messages" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags"]

           "CAP REQ message-tags", _state ->
             [":irc.test CAP * ACK :message-tags"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@+typing=active :alice!a@example.test TAGMSG #elixir"
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
        caps: ["message-tags"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:tagmsg,
                     %{
                       nick: "alice",
                       target: "#elixir",
                       tags: %{"+typing" => "active"}
                     }}},
                   1_000

    assert :ok = Ircxd.Client.tagmsg(client, "#elixir", %{"+typing" => "done"})
    assert_receive {:scripted_irc_line, "@+typing=done TAGMSG #elixir"}, 1_000
  end
end
