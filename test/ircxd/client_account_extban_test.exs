defmodule Ircxd.ClientAccountExtbanTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "builds account extban masks from negotiated ISUPPORT tokens" do
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
               ":irc.test 005 nick EXTBAN=$,ARar ACCOUNTEXTBAN=R :are supported by this server"
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
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:isupport, %{"ACCOUNTEXTBAN" => "R"}}}, 1_000

    assert Ircxd.Client.account_extban_mask(client, "bob") == {:ok, "$R:bob"}
  end
end
