defmodule Ircxd.ClientEventPipelineTest do
  use ExUnit.Case, async: false

  alias Ircxd.Message
  alias Ircxd.Client.Event
  alias Ircxd.ScriptedIrcServer

  test "correlates labeled and batched NAMES, WHO, and WHOX events" do
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

           "@label=names-1 NAMES #elixir", _state ->
             [
               "@label=names-1 :irc.test BATCH +names-batch labeled-response",
               "@batch=names-batch :irc.test 353 nick = #elixir :@alice bob",
               "@batch=names-batch :irc.test 366 nick #elixir :End of /NAMES list",
               ":irc.test BATCH -names-batch"
             ]

           "@label=who-1 WHO #elixir", _state ->
             [
               "@label=who-1 :irc.test BATCH +who-batch labeled-response",
               "@batch=who-batch :irc.test 352 nick #elixir user host irc.test alice H@ :0 Alice",
               "@batch=who-batch :irc.test 315 nick #elixir :End of /WHO list",
               ":irc.test BATCH -who-batch"
             ]

           "@label=whox-1 WHO #elixir %tcuhsnfar,42", _state ->
             [
               "@label=whox-1 :irc.test BATCH +whox-batch labeled-response",
               "@batch=whox-batch :irc.test 354 nick 42 #elixir user host irc.test alice H account :Alice",
               "@batch=whox-batch :irc.test 315 nick #elixir :End of /WHO list",
               ":irc.test BATCH -whox-batch"
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

    assert :ok = Ircxd.Client.labeled_raw(client, "names-1", "NAMES", ["#elixir"])

    assert_pipeline_event(:names, "names-1", "names-batch", "353")
    assert_pipeline_event(:names_end, "names-1", "names-batch", "366")
    assert_labeled_batch("names-1", [:names, :names_end])

    assert :ok = Ircxd.Client.labeled_raw(client, "who-1", "WHO", ["#elixir"])

    assert_pipeline_event(:who_reply, "who-1", "who-batch", "352")
    assert_pipeline_event(:who_end, "who-1", "who-batch", "315")
    assert_labeled_batch("who-1", [:who_reply, :who_end])

    assert :ok =
             Ircxd.Client.labeled_raw(client, "whox-1", "WHO", ["#elixir", "%tcuhsnfar,42"])

    assert_pipeline_event(:whox_reply, "whox-1", "whox-batch", "354")
    assert_pipeline_event(:who_end, "whox-1", "whox-batch", "315")
    assert_labeled_batch("whox-1", [:whox_reply, :who_end])
  end

  test "completes an ACK-only labeled request" do
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

           "@label=pong-1 PONG token", _state ->
             ["@label=pong-1 :irc.test ACK"]

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
    assert :ok = Ircxd.Client.labeled_raw(client, "pong-1", "PONG", ["token"])

    assert_receive {:ircxd, {:labeled_request, %{label: "pong-1", status: :acknowledged}}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "pong-1", status: :completed, response_type: :ack}}},
                   1_000
  end

  test "inherits labels through applicable and nested batch types" do
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

           "@label=history-1 VENDORQUERY #room", _state ->
             [
               "@label=history-1 :irc.test BATCH +history draft/chathistory #room",
               "@batch=history :irc.test BATCH +nested example.test/nested",
               "@batch=nested :alice!user@host PRIVMSG #room :hello",
               "@batch=nested;+typing=active :alice!user@host TAGMSG nick",
               "@batch=history :irc.test BATCH -nested",
               ":irc.test BATCH -history"
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

    assert :ok = Ircxd.Client.labeled_raw(client, "history-1", "VENDORQUERY", ["#room"])

    assert_receive {:ircxd,
                    {:privmsg,
                     %{
                       label: "history-1",
                       batch: "nested",
                       raw_message: %Message{command: "PRIVMSG"}
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{
                       label: "history-1",
                       event:
                         {:batch, %{ref: "history", type: "draft/chathistory", events: events}}
                     }}},
                   1_000

    assert Enum.any?(events, &match?({:privmsg, _payload}, &1))

    assert_receive {:ircxd,
                    {:typing,
                     %{
                       label: "history-1",
                       batch: "nested",
                       target: "nick",
                       target_self?: true
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "history-1", status: :completed, response_type: :batch}}},
                   1_000
  end

  test "routes labeled CAP replies through correlation and envelope metadata" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :labeled-response batch echo-message"]

           "CAP REQ :labeled-response batch", _state ->
             [":irc.test CAP * ACK :labeled-response batch"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=cap-1 CAP REQ echo-message", _state ->
             ["@label=cap-1 :irc.test CAP nick ACK :echo-message"]

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
        caps: ["labeled-response", "batch"],
        events: :both,
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "cap-1", "CAP", ["REQ", "echo-message"])

    assert_receive {:ircxd, {:cap_ack, ["echo-message"]}}, 1_000

    assert_receive {:ircxd,
                    %Event{
                      name: :cap_ack,
                      payload: ["echo-message"],
                      message: %Message{command: "CAP"},
                      label: "cap-1",
                      origin: :message
                    }},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "cap-1", status: :completed, response_type: :single}}},
                   1_000
  end

  defp assert_pipeline_event(name, label, batch, command) do
    assert_receive {:ircxd,
                    {^name,
                     %{
                       label: ^label,
                       batch: ^batch,
                       raw_message: %Message{command: ^command}
                     }}},
                   1_000

    assert_receive {:ircxd, {:batched, %{ref: ^batch, event: {^name, _payload}}}}, 1_000
  end

  defp assert_labeled_batch(label, expected_names) do
    assert_receive {:ircxd,
                    {:labeled_response, %{label: ^label, event: {:batch, %{events: events}}}}},
                   1_000

    assert Enum.map(events, &elem(&1, 0)) == expected_names
  end
end
