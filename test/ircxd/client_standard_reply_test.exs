defmodule Ircxd.ClientStandardReplyTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits typed IRCv3 standard reply events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :standard-replies"]

           "CAP REQ standard-replies", _state ->
             [":irc.test CAP * ACK :standard-replies"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "FAIL * NEED_REGISTRATION :register first",
               "WARN AUTHENTICATE RATE_LIMITED PLAIN :slow down",
               "NOTE * SERVER_NOTICE :maintenance soon",
               "FAIL authenticate rate_limited plain :retry later"
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
        caps: ["standard-replies"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:standard_reply,
                     %{
                       type: :fail,
                       command: "*",
                       code: "NEED_REGISTRATION",
                       description: "register first"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:standard_reply,
                     %{
                       type: :warn,
                       command: "AUTHENTICATE",
                       code: "RATE_LIMITED",
                       context: ["PLAIN"],
                       description: "slow down"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:standard_reply,
                     %{
                       type: :note,
                       command: "*",
                       code: "SERVER_NOTICE",
                       description: "maintenance soon"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:standard_reply,
                     %{
                       type: :fail,
                       command: "AUTHENTICATE",
                       code: "RATE_LIMITED",
                       context: ["plain"],
                       description: "retry later"
                     }}},
                   1_000
  end

  test "emits labeled-response lifecycle for labeled standard replies" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags labeled-response standard-replies"]

           "CAP REQ :message-tags labeled-response standard-replies", _state ->
             [":irc.test CAP * ACK :message-tags labeled-response standard-replies"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "@label=req-std HELP missing", _state ->
             ["@label=req-std FAIL HELP UNKNOWN_COMMAND missing :No help for that subject"]

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
        caps: ["message-tags", "labeled-response", "standard-replies"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.labeled_raw(client, "req-std", "HELP", ["missing"])

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "req-std", status: :sent, command: "HELP", params: ["missing"]}}},
                   1_000

    assert_receive {:ircxd,
                    {:standard_reply,
                     %{
                       type: :fail,
                       command: "HELP",
                       code: "UNKNOWN_COMMAND",
                       context: ["missing"],
                       description: "No help for that subject"
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{
                       label: "req-std",
                       event:
                         {:standard_reply,
                          %{
                            type: :fail,
                            command: "HELP",
                            code: "UNKNOWN_COMMAND"
                          }}
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "req-std", status: :completed, response_type: :single}}},
                   1_000
  end
end
