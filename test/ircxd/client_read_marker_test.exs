defmodule Ircxd.ClientReadMarkerTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends MARKREAD get/set commands and emits read marker events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/read-marker"]

           "CAP REQ draft/read-marker", _state ->
             [":irc.test CAP * ACK :draft/read-marker"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "MARKREAD #chan", _state ->
             [":irc.test MARKREAD #chan timestamp=2026-05-13T08:00:00.000Z"]

           "MARKREAD #chan timestamp=2026-05-13T08:01:00.000Z", _state ->
             [":irc.test MARKREAD #chan *"]

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
        caps: ["draft/read-marker"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.markread_get(client, "#chan")
    assert_receive {:scripted_irc_line, "MARKREAD #chan"}, 1_000

    assert_receive {:ircxd,
                    {:read_marker,
                     %{target: "#chan", timestamp: %DateTime{} = timestamp, known?: true}}},
                   1_000

    assert DateTime.to_iso8601(timestamp) == "2026-05-13T08:00:00.000Z"

    assert :ok =
             Ircxd.Client.markread_set(client, "#chan", "2026-05-13T08:01:00.000Z")

    assert_receive {:scripted_irc_line, "MARKREAD #chan timestamp=2026-05-13T08:01:00.000Z"},
                   1_000

    assert_receive {:ircxd, {:read_marker, %{target: "#chan", timestamp: nil, known?: false}}},
                   1_000
  end

  test "rejects MARKREAD before draft/read-marker is negotiated" do
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

    assert {:error, {:capability_not_enabled, "draft/read-marker"}} =
             Ircxd.Client.markread_get(client, "#chan")

    refute_receive {:scripted_irc_line, "MARKREAD #chan"}, 250
  end
end
