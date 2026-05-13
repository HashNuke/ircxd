defmodule Ircxd.ClientLabeledResponseTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits labeled_response events for server replies with label tags" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags labeled-response"]

           "CAP REQ :message-tags labeled-response", _state ->
             [":irc.test CAP * ACK :message-tags labeled-response"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=req-1 WHOIS alice", _state ->
             ["@label=req-1 :irc.test 318 nick alice :End of /WHOIS list"]

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
        caps: ["message-tags", "labeled-response"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "req-1", "WHOIS", ["alice"])

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{
                       label: "req-1",
                       event: {:whois_end, %{nick: "alice"}},
                       message: %{command: "318"}
                     }}},
                   1_000
  end
end
