defmodule Ircxd.ClientSTSTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer
  alias Ircxd.Client.Event
  alias Ircxd.Message

  test "emits STS policy events and does not request the sts capability" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sts=port=6697 message-tags"]

           "CAP REQ message-tags", _state ->
             [":irc.test CAP * ACK :message-tags"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           _line, _state ->
             []
         end}
      )

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["sts", "message-tags"],
        events: :both,
        notify: self()
      )

    assert_receive {:ircxd,
                    {:sts_policy, %{host: "127.0.0.1", type: :upgrade, port: 6697, tls?: false}}},
                   1_000

    assert_receive {:ircxd,
                    %Event{
                      name: :sts_policy,
                      payload: %{raw_message: %Message{command: "CAP"}},
                      message: %Message{command: "CAP"},
                      origin: :derivative,
                      derivative?: true
                    }},
                   1_000

    assert_receive {:scripted_irc_line, "CAP REQ message-tags"}, 1_000
    Process.sleep(250)
    refute Enum.any?(ScriptedIrcServer.lines(server), &String.contains?(&1, "CAP REQ sts"))
  end

  test "ignores CAP DEL sts" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sts=port=6697"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test CAP * DEL :sts",
               ":irc.test CAP * DEL :sts message-tags"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        notify: self()
      )

    assert_receive {:ircxd, {:sts_policy, %{type: :upgrade, port: 6697}}}, 1_000
    refute_receive {:ircxd, {:cap_del, []}}, 1_000
    refute_receive {:ircxd, {:cap_del, ["sts"]}}, 1_000
    assert_receive {:ircxd, {:cap_del, ["message-tags"]}}, 1_000
  end

  test "emits STS policy errors for invalid advertised policies" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sts=port=not-a-port"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           _line, _state ->
             []
         end}
      )

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        notify: self()
      )

    assert_receive {:ircxd,
                    {:sts_policy_error,
                     %{
                       host: "127.0.0.1",
                       value: "port=not-a-port",
                       reason: :invalid_sts_policy
                     }}},
                   1_000
  end

  test "treats STS as metadata rather than a second labeled CAP response" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :labeled-response batch sts=port=6697"]

           "CAP REQ :labeled-response batch", _state ->
             [":irc.test CAP * ACK :labeled-response batch"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=sts-1 VENDOR", _state ->
             ["@label=sts-1 :irc.test CAP nick NEW :sts=port=7000"]

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
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "sts-1", "VENDOR", [])

    assert_receive {:ircxd, {:sts_policy, %{port: 7000, label: "sts-1"}}}, 1_000

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{label: "sts-1", event: {:cap_new, %{"sts" => "port=7000"}}}}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "sts-1", status: :completed, response_type: :single}}},
                   1_000

    refute_receive {:ircxd, {:labeled_response, %{label: "sts-1"}}}, 100
  end
end
