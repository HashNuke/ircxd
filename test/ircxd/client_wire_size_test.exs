defmodule Ircxd.ClientWireSizeTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "rejects outbound messages that exceed IRC wire size limits" do
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
        caps: ["message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert {:error, :line_too_long} =
             Ircxd.Client.privmsg(client, "#chan", String.duplicate("a", 512))

    assert {:error, :line_too_long} =
             Ircxd.Client.privmsg(client, "#chan", "hello", %{
               "+draft/oversized" => String.duplicate("t", 4_095)
             })
  end
end
