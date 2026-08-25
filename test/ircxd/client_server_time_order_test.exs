defmodule Ircxd.ClientServerTimeOrderTest do
  use ExUnit.Case, async: false

  alias Ircxd.Client.Event
  alias Ircxd.ScriptedIrcServer

  test "optionally buffers server-time events and flushes them in timestamp order" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :server-time"]

           "CAP REQ server-time", _state ->
             [":irc.test CAP * ACK :server-time"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@time=2026-05-13T07:00:02.000Z :alice!a@example.test PRIVMSG #elixir :third",
               "@time=2026-05-13T07:00:01.000Z :alice!a@example.test PRIVMSG #elixir :second",
               "@time=2026-05-13T07:00:00.000Z :alice!a@example.test PRIVMSG #elixir :first"
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
        caps: ["server-time"],
        server_time_order: :manual,
        notify: self()
      )

    assert_receive {:ircxd,
                    {:message, %Ircxd.Message{command: "PRIVMSG", params: ["#elixir", "first"]}}},
                   1_000

    refute_receive {:ircxd, {:privmsg, _payload}}, 100

    assert :ok = Ircxd.Client.flush_server_time(client)

    assert_receive {:ircxd, {:privmsg, %{body: "first"}}}, 1_000
    assert_receive {:ircxd, {:privmsg, %{body: "second"}}}, 1_000
    assert_receive {:ircxd, {:privmsg, %{body: "third"}}}, 1_000
  end

  test "buffers timestamped structured events using their raw message" do
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
               "@time=2026-05-13T07:00:00.000Z :irc.test 315 nick #room :End of WHO"
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
        events: :both,
        server_time_order: :manual,
        notify: self()
      )

    assert_receive {:ircxd, {:message, %Ircxd.Message{command: "315"}}}, 1_000
    refute_receive {:ircxd, {:who_end, _payload}}, 100
    refute_receive {:ircxd, %Event{name: :who_end}}, 100

    assert :ok = Ircxd.Client.flush_server_time(client)
    assert_receive {:ircxd, {:who_end, %{mask: "#room"}}}, 1_000
    assert_receive {:ircxd, %Event{name: :who_end, server_time: %DateTime{}}}, 1_000
  end

  test "collects timestamped batch members before an untimed labeled batch closes" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch labeled-response message-tags server-time"]

           "CAP REQ :batch labeled-response message-tags server-time", _state ->
             [":irc.test CAP * ACK :batch labeled-response message-tags server-time"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=who-1 WHO #room", _state ->
             [
               "@label=who-1 BATCH +responses labeled-response",
               "@batch=responses;time=2026-05-13T07:00:01.000Z :irc.test 352 nick #room user host irc.test alice H :0 Alice",
               "@batch=responses;time=2026-05-13T07:00:02.000Z :irc.test 315 nick #room :End of WHO",
               "BATCH -responses"
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
        caps: ["batch", "labeled-response", "message-tags", "server-time"],
        server_time_order: :manual,
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "who-1", "WHO", ["#room"])

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{
                       label: "who-1",
                       event:
                         {:batch,
                          %{
                            ref: "responses",
                            events: [{:who_reply, _reply}, {:who_end, _ending}]
                          }}
                     }}},
                   1_000

    refute_receive {:ircxd, {:who_reply, _payload}}, 100
    assert :ok = Ircxd.Client.flush_server_time(client)

    assert_receive {:ircxd, {:who_reply, %{batch: "responses", label: "who-1"}}}, 1_000
    assert_receive {:ircxd, {:who_end, %{batch: "responses", label: "who-1"}}}, 1_000

    assert_receive {:ircxd,
                    {:batched,
                     %{
                       ref: "responses",
                       batch: %{type: "labeled-response"},
                       event: {:who_reply, _payload}
                     }}},
                   1_000
  end

  test "collects timestamped multiline members before an untimed batch close" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch draft/multiline message-tags server-time"]

           "CAP REQ :batch draft/multiline message-tags server-time", _state ->
             [":irc.test CAP * ACK :batch draft/multiline message-tags server-time"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":alice!user@host BATCH +multi draft/multiline #room",
               "@batch=multi;time=2026-05-13T07:00:01.000Z :alice!user@host PRIVMSG #room :hello ",
               "@batch=multi;time=2026-05-13T07:00:02.000Z;draft/multiline-concat :alice!user@host PRIVMSG #room :world",
               "BATCH -multi"
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
        caps: ["batch", "draft/multiline", "message-tags", "server-time"],
        server_time_order: :manual,
        notify: self()
      )

    assert_receive {:ircxd,
                    {:multiline,
                     %{ref: "multi", body: "hello world", batch: %{type: "draft/multiline"}}}},
                   1_000

    refute_receive {:ircxd, {:privmsg, _payload}}, 100
    assert :ok = Ircxd.Client.flush_server_time(client)

    assert_receive {:ircxd,
                    {:batched,
                     %{ref: "multi", batch: %{type: "draft/multiline"}, event: {:privmsg, _}}}},
                   1_000
  end

  test "completes a timestamped direct labeled response before disconnect" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch labeled-response message-tags server-time"]

           "CAP REQ :batch labeled-response message-tags server-time", _state ->
             [":irc.test CAP * ACK :batch labeled-response message-tags server-time"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=who-2 WHO #room", _state ->
             [
               "@label=who-2;time=2026-05-13T07:00:01.000Z :irc.test 315 nick #room :End of WHO"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} = start_labeled_server_time_client(server)
    client_ref = Process.monitor(client)

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "who-2", "WHO", ["#room"])
    assert_receive {:ircxd, {:message, %Ircxd.Message{command: "315"}}}, 1_000

    GenServer.stop(server)

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "who-2", status: :completed, response_type: :single}}},
                   1_000

    refute_receive {:ircxd, {:labeled_request, %{label: "who-2", status: :failed}}}, 100
    assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1_000
  end

  test "completes a timestamped labeled ACK before disconnect" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch labeled-response message-tags server-time"]

           "CAP REQ :batch labeled-response message-tags server-time", _state ->
             [":irc.test CAP * ACK :batch labeled-response message-tags server-time"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=pong-2 PONG token", _state ->
             ["@label=pong-2;time=2026-05-13T07:00:01.000Z :irc.test ACK"]

           _line, _state ->
             []
         end}
      )

    {:ok, client} = start_labeled_server_time_client(server)
    client_ref = Process.monitor(client)

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "pong-2", "PONG", ["token"])
    assert_receive {:ircxd, {:message, %Ircxd.Message{command: "ACK"}}}, 1_000

    GenServer.stop(server)

    assert_receive {:ircxd, {:labeled_request, %{label: "pong-2", status: :acknowledged}}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "pong-2", status: :completed, response_type: :ack}}},
                   1_000

    refute_receive {:ircxd, {:labeled_request, %{label: "pong-2", status: :failed}}}, 100
    assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1_000
  end

  test "publishes a buffered labeled response without repeating its lifecycle completion" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch labeled-response message-tags server-time"]

           "CAP REQ :batch labeled-response message-tags server-time", _state ->
             [":irc.test CAP * ACK :batch labeled-response message-tags server-time"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=who-3 WHO #room", _state ->
             [
               "@label=who-3;time=2026-05-13T07:00:01.000Z :irc.test 315 nick #room :End of WHO"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} = start_labeled_server_time_client(server)

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "who-3", "WHO", ["#room"])

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "who-3", status: :completed, response_type: :single}}},
                   1_000

    refute_receive {:ircxd, {:labeled_response, %{label: "who-3"}}}, 100
    assert :ok = Ircxd.Client.flush_server_time(client)
    assert_receive {:ircxd, {:labeled_response, %{label: "who-3"}}}, 1_000

    refute_receive {:ircxd, {:labeled_request, %{label: "who-3", status: :completed}}},
                   100
  end

  test "fails a timestamped standard FAIL request before disconnect" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [
               ":irc.test CAP * LS :batch labeled-response message-tags server-time standard-replies"
             ]

           "CAP REQ :batch labeled-response message-tags server-time standard-replies", _state ->
             [
               ":irc.test CAP * ACK :batch labeled-response message-tags server-time standard-replies"
             ]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=help-1 HELP missing", _state ->
             [
               "@label=help-1;time=2026-05-13T07:00:01.000Z :irc.test FAIL HELP UNKNOWN_COMMAND missing :No help for that subject"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      start_labeled_server_time_client(server, [
        "batch",
        "labeled-response",
        "message-tags",
        "server-time",
        "standard-replies"
      ])

    client_ref = Process.monitor(client)
    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "help-1", "HELP", ["missing"])
    assert_receive {:ircxd, {:message, %Ircxd.Message{command: "FAIL"}}}, 1_000

    GenServer.stop(server)

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{
                       label: "help-1",
                       status: :failed,
                       response_type: :single,
                       reason:
                         {:standard_reply,
                          %{type: :fail, command: "HELP", code: "UNKNOWN_COMMAND"}}
                     }}},
                   1_000

    refute_receive {:ircxd, {:labeled_request, %{label: "help-1", status: :completed}}},
                   100

    assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1_000
  end

  test "fails a timestamped error numeric request before disconnect" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch labeled-response message-tags server-time"]

           "CAP REQ :batch labeled-response message-tags server-time", _state ->
             [":irc.test CAP * ACK :batch labeled-response message-tags server-time"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=join-1 JOIN #private", _state ->
             [
               "@label=join-1;time=2026-05-13T07:00:01.000Z :irc.test 473 nick #private :Cannot join channel (+i)"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} = start_labeled_server_time_client(server)
    client_ref = Process.monitor(client)
    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "join-1", "JOIN", ["#private"])
    assert_receive {:ircxd, {:message, %Ircxd.Message{command: "473"}}}, 1_000

    GenServer.stop(server)

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{
                       label: "join-1",
                       status: :failed,
                       response_type: :single,
                       reason: {:irc_error, %{code: "473", target: "#private"}}
                     }}},
                   1_000

    refute_receive {:ircxd, {:labeled_request, %{label: "join-1", status: :completed}}},
                   100

    assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1_000
  end

  defp start_labeled_server_time_client(
         server,
         caps \\ [
           "batch",
           "labeled-response",
           "message-tags",
           "server-time"
         ]
       ) do
    Ircxd.start_link(
      host: "127.0.0.1",
      port: ScriptedIrcServer.port(server),
      nick: "nick",
      username: "nick",
      realname: "Nick",
      caps: caps,
      server_time_order: :manual,
      notify: self()
    )
  end
end
