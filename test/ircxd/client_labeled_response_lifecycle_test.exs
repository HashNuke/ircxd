defmodule Ircxd.ClientLabeledResponseLifecycleTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "tracks labeled-response request lifecycle from send through ACK and batch completion" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags labeled-response batch"]

           "CAP REQ :message-tags labeled-response batch", _state ->
             [":irc.test CAP * ACK :message-tags labeled-response batch"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=list-2 LIST", _state ->
             [
               "@label=list-2 ACK",
               "@label=list-2 BATCH +lb2 labeled-response",
               "@batch=lb2 :irc.test 321 nick Channel :Users Name",
               "@batch=lb2 :irc.test 323 nick :End of /LIST",
               "BATCH -lb2"
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
        caps: ["message-tags", "labeled-response", "batch"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "list-2", "LIST", [])

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "list-2", status: :sent, command: "LIST", params: []}}},
                   1_000

    assert_receive {:ircxd, {:labeled_request, %{label: "list-2", status: :acknowledged}}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "list-2", status: :completed, response_type: :batch}}},
                   1_000
  end
end
