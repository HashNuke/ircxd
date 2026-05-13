defmodule Ircxd.ClientClientTagDenyTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "exposes CLIENTTAGDENY decisions from ISUPPORT" do
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
               ":irc.test 005 nick CLIENTTAGDENY=*,-reply :are supported by this server"
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

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:isupport, %{"CLIENTTAGDENY" => "*,-reply"}}}, 1_000

    assert Ircxd.Client.client_tag_denied?(client, "+typing") == true
    assert Ircxd.Client.client_tag_denied?(client, "+reply") == false
  end
end
