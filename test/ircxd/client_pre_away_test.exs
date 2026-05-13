defmodule Ircxd.ClientPreAwayTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends AWAY states and treats AWAY * as unspecified absence" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/pre-away away-notify"]

           "CAP REQ :draft/pre-away away-notify", _state ->
             [":irc.test CAP * ACK :draft/pre-away away-notify"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "AWAY *", _state ->
             [":alice!user@host AWAY :*"]

           "AWAY :back later", _state ->
             [":alice!user@host AWAY :back later"]

           "AWAY", _state ->
             [":alice!user@host AWAY"]

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
        caps: ["draft/pre-away", "away-notify"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.preaway_unspecified(client)
    assert_receive {:scripted_irc_line, "AWAY *"}, 1_000
    assert_receive {:ircxd, {:away, %{nick: "alice", away?: true, unspecified?: true}}}, 1_000

    assert :ok = Ircxd.Client.away(client, "back later")
    assert_receive {:scripted_irc_line, "AWAY :back later"}, 1_000

    assert_receive {:ircxd,
                    {:away,
                     %{
                       nick: "alice",
                       away?: true,
                       message: "back later",
                       unspecified?: false
                     }}},
                   1_000

    assert :ok = Ircxd.Client.away(client)
    assert_receive {:scripted_irc_line, "AWAY"}, 1_000
    assert_receive {:ircxd, {:away, %{nick: "alice", away?: false, message: nil}}}, 1_000
  end

  test "rejects AWAY * before draft/pre-away is negotiated" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

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

    assert {:error, {:capability_not_enabled, "draft/pre-away"}} =
             Ircxd.Client.preaway_unspecified(client)

    refute_receive {:scripted_irc_line, "AWAY *"}, 250
  end
end
