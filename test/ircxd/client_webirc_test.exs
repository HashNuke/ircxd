defmodule Ircxd.ClientWebIRCTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends WEBIRC before capability negotiation when configured" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "WEBIRC hunter2 ExampleGateway 198.51.100.3 198.51.100.3 secure", _state ->
             []

           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

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
        webirc: [
          password: "hunter2",
          gateway: "ExampleGateway",
          hostname: "198.51.100.3",
          ip: "198.51.100.3",
          options: [{"secure", true}]
        ],
        notify: self()
      )

    assert_receive {:scripted_irc_line,
                    "WEBIRC hunter2 ExampleGateway 198.51.100.3 198.51.100.3 secure"},
                   1_000

    assert_receive {:scripted_irc_line, "CAP LS 302"}, 1_000
    assert_receive {:scripted_irc_line, "NICK nick"}, 1_000
    assert_receive {:scripted_irc_line, "USER nick 0 * Nick"}, 1_000
    assert_receive {:ircxd, :registered}, 1_000
  end
end
