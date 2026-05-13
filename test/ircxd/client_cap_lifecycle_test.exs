defmodule Ircxd.ClientCapLifecycleTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits CAP NAK and ends capability negotiation" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * NAK :sasl"]

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
        caps: ["sasl"],
        notify: self()
      )

    assert_receive {:ircxd, {:cap_nak, ["sasl"]}}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end

  test "updates advertised capabilities on CAP NEW and DEL" do
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
               ":irc.test CAP * NEW :server-time message-tags",
               ":irc.test CAP * DEL :message-tags"
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

    assert_receive {:ircxd, {:cap_new, %{"server-time" => true, "message-tags" => true}}},
                   1_000

    assert_receive {:ircxd, {:cap_del, ["message-tags"]}}, 1_000
  end

  test "allows host applications to request capabilities advertised by CAP NEW" do
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
               ":irc.test CAP * NEW :server-time message-tags"
             ]

           "CAP REQ :server-time message-tags", _state ->
             [":irc.test CAP * ACK :server-time message-tags"]

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

    assert_receive {:ircxd, {:cap_new, %{"server-time" => true, "message-tags" => true}}},
                   1_000

    assert :ok = Ircxd.Client.request_capabilities(client, ["server-time", "message-tags"])
    assert_receive {:scripted_irc_line, "CAP REQ :server-time message-tags"}, 1_000
    assert_receive {:ircxd, {:cap_ack, ["server-time", "message-tags"]}}, 1_000

    assert {:error, {:capabilities_not_available, ["missing-cap"]}} =
             Ircxd.Client.request_capabilities(client, ["missing-cap"])

    assert {:error, :missing_capabilities} = Ircxd.Client.request_capabilities(client, [])
  end

  test "uses CAP NEW value updates for later capability requests" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl=PLAIN"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":irc.test CAP * NEW :sasl=PLAIN,EXTERNAL"
             ]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE EXTERNAL", _state ->
             []

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
        sasl: {:external, "nick"},
        notify: self()
      )

    assert_receive {:ircxd, {:cap_ls, %{"sasl" => "PLAIN"}}}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_new, %{"sasl" => "PLAIN,EXTERNAL"}}}, 1_000

    assert :ok = Ircxd.Client.request_capabilities(client, ["sasl"])
    assert_receive {:scripted_irc_line, "CAP REQ sasl"}, 1_000
    assert_receive {:ircxd, {:cap_ack, ["sasl"]}}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE EXTERNAL"}, 1_000
  end

  test "keeps the final duplicate capability value from left-to-right parsing" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :sasl=PLAIN sasl=EXTERNAL"]

           "CAP REQ sasl", _state ->
             [":irc.test CAP * ACK :sasl"]

           "AUTHENTICATE EXTERNAL", _state ->
             []

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
        sasl: {:external, "nick"},
        notify: self()
      )

    assert_receive {:ircxd, {:cap_ls, %{"sasl" => "EXTERNAL"}}}, 1_000
    assert_receive {:scripted_irc_line, "CAP REQ sasl"}, 1_000
    assert_receive {:ircxd, {:cap_ack, ["sasl"]}}, 1_000
    assert_receive {:scripted_irc_line, "AUTHENTICATE EXTERNAL"}, 1_000
  end

  test "lists active capabilities with multiline CAP LIST replies" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags server-time"]

           "CAP REQ :message-tags server-time", _state ->
             [":irc.test CAP * ACK :message-tags server-time"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "CAP LIST", _state ->
             [
               ":irc.test CAP * LIST * :message-tags",
               ":irc.test CAP * LIST :server-time"
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
        caps: ["message-tags", "server-time"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.cap_list(client)
    assert_receive {:scripted_irc_line, "CAP LIST"}, 1_000

    assert_receive {:ircxd, {:cap_list, %{"message-tags" => true, "server-time" => true}}},
                   1_000
  end

  test "removes active capabilities when CAP ACK disables them" do
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

           "CAP REQ -message-tags", _state ->
             [":irc.test CAP * ACK :-message-tags"]

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

    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.typing(client, "#elixir", :active)
    assert_receive {:scripted_irc_line, "@+typing=active TAGMSG #elixir"}, 1_000

    assert :ok = Ircxd.Client.disable_capabilities(client, ["message-tags"])
    assert_receive {:scripted_irc_line, "CAP REQ -message-tags"}, 1_000
    assert_receive {:ircxd, {:cap_ack, ["-message-tags"]}}, 1_000
    refute_receive {:scripted_irc_line, "CAP END"}, 250

    assert {:error, {:capability_not_enabled, "message-tags"}} =
             Ircxd.Client.typing(client, "#elixir", :done)

    assert {:error, {:capabilities_not_enabled, ["message-tags"]}} =
             Ircxd.Client.disable_capabilities(client, ["message-tags"])

    assert {:error, :missing_capabilities} = Ircxd.Client.disable_capabilities(client, [])

    refute_receive {:scripted_irc_line, "@+typing=done TAGMSG #elixir"}, 250
  end

  test "does not send CAP END after post-registration CAP NAK" do
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
               ":irc.test CAP * NEW :server-time"
             ]

           "CAP REQ server-time", _state ->
             [":irc.test CAP * NAK :server-time"]

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

    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_new, %{"server-time" => true}}}, 1_000

    assert :ok = Ircxd.Client.request_capabilities(client, ["server-time"])
    assert_receive {:scripted_irc_line, "CAP REQ server-time"}, 1_000
    assert_receive {:ircxd, {:cap_nak, ["server-time"]}}, 1_000
    refute_receive {:scripted_irc_line, "CAP END"}, 250
  end

  test "aggregates multiline CAP LS replies before requesting capabilities" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [
               ":irc.test CAP * LS * :server-time sasl=PLAIN,EXTERNAL",
               ":irc.test CAP * LS :message-tags echo-message"
             ]

           "CAP REQ :sasl server-time echo-message", _state ->
             [":irc.test CAP * ACK :sasl server-time echo-message"]

           "AUTHENTICATE PLAIN", _state ->
             [":irc.test 904 nick SASL :SASL authentication failed"]

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
        caps: ["sasl", "server-time", "echo-message"],
        sasl: {:plain, "nick", "secret"},
        notify: self()
      )

    refute_receive {:scripted_irc_line, "CAP REQ sasl"}, 250

    assert_receive {:ircxd,
                    {:cap_ls,
                     %{
                       "sasl" => "PLAIN,EXTERNAL",
                       "server-time" => true,
                       "message-tags" => true,
                       "echo-message" => true
                     }}},
                   1_000

    assert_receive {:scripted_irc_line, "CAP REQ :sasl server-time echo-message"}, 1_000
    assert_receive {:ircxd, {:cap_ack, ["sasl", "server-time", "echo-message"]}}, 1_000
    assert_receive {:ircxd, {:sasl_failure, %{code: "904"}}}, 1_000
    assert_receive {:scripted_irc_line, "CAP END"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end
end
