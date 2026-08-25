defmodule Ircxd.ClientActionTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends a CTCP ACTION as a PRIVMSG" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

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

    assert :ok = Ircxd.Client.action(client, "#elixir", "waves hello")
    assert_receive {:scripted_irc_line, "PRIVMSG #elixir :\x01ACTION waves hello\x01"}, 1_000
  end
end
