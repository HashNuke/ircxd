defmodule Ircxd.ClientLabeledResponseBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed ACK and batch-level labeled_response events" do
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

           "@label=list-1 LIST", _state ->
             [
               "@label=list-1 ACK",
               "@label=list-1 BATCH +lb1 labeled-response",
               "@batch=lb1 :irc.test 321 nick Channel :Users Name",
               "@batch=lb1 :irc.test 322 nick #elixir 10 :Elixir",
               "@batch=lb1 :irc.test 323 nick :End of /LIST",
               "BATCH -lb1"
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
    assert :ok = Ircxd.Client.labeled_raw(client, "list-1", "LIST", [])

    assert_receive {:ircxd,
                    {:labeled_response, %{label: "list-1", event: {:ack, %{label: "list-1"}}}}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{
                       label: "list-1",
                       event:
                         {:batch,
                          %{
                            ref: "lb1",
                            type: "labeled-response",
                            events: [
                              {:list_start, %{params: ["nick", "Channel", "Users Name"]}},
                              {:list_entry,
                               %{channel: "#elixir", visible: "10", topic: "Elixir"}},
                              {:list_end, %{params: ["nick", "End of /LIST"]}}
                            ]
                          }}
                     }}},
                   1_000
  end
end
