defmodule Ircxd.ClientLabeledResponseBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits batch-level labeled_response events" do
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

  test "fails a labeled batch lifecycle when the batch contains a standard FAIL" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags labeled-response standard-replies batch"]

           "CAP REQ :message-tags labeled-response standard-replies batch", _state ->
             [":irc.test CAP * ACK :message-tags labeled-response standard-replies batch"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=batch-fail HELP missing", _state ->
             [
               "@label=batch-fail BATCH +failed-response labeled-response",
               "@batch=failed-response :irc.test FAIL HELP UNKNOWN_COMMAND missing :No help for that subject",
               "BATCH -failed-response"
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
        caps: ["message-tags", "labeled-response", "standard-replies", "batch"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "batch-fail", "HELP", ["missing"])

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{
                       label: "batch-fail",
                       status: :failed,
                       response_type: :batch,
                       reason:
                         {:standard_reply,
                          %{type: :fail, command: "HELP", code: "UNKNOWN_COMMAND"}}
                     }}},
                   1_000

    refute_receive {:ircxd, {:labeled_request, %{label: "batch-fail", status: :completed}}},
                   100
  end
end
