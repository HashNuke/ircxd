defmodule Ircxd.ClientChannelRenameTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends RENAME and emits draft channel rename events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/channel-rename"]

           "CAP REQ draft/channel-rename", _state ->
             [":irc.test CAP * ACK :draft/channel-rename"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "RENAME #old #new :Typo fix", _state ->
             [":nick!user@host RENAME #old #new :Typo fix"]

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
        caps: ["draft/channel-rename"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert :ok = Ircxd.Client.rename(client, "#old", "#new", "Typo fix")
    assert_receive {:scripted_irc_line, "RENAME #old #new :Typo fix"}, 1_000

    assert_receive {:ircxd,
                    {:channel_rename,
                     %{
                       nick: "nick",
                       old_channel: "#old",
                       new_channel: "#new",
                       reason: "Typo fix"
                     }}},
                   1_000
  end

  test "rejects RENAME before draft/channel-rename is negotiated" do
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

    assert {:error, {:capability_not_enabled, "draft/channel-rename"}} =
             Ircxd.Client.rename(client, "#old", "#new", "Typo fix")

    refute_receive {:scripted_irc_line, "RENAME #old #new :Typo fix"}, 250
  end

  test "rejects RENAME after draft/channel-rename is deleted" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/channel-rename"]

           "CAP REQ draft/channel-rename", _state ->
             [":irc.test CAP * ACK :draft/channel-rename"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome", ":irc.test CAP * DEL :draft/channel-rename"]

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
        caps: ["draft/channel-rename"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:cap_del, ["draft/channel-rename"]}}, 1_000

    assert {:error, {:capability_not_enabled, "draft/channel-rename"}} =
             Ircxd.Client.rename(client, "#old", "#new", "Typo fix")

    refute_receive {:scripted_irc_line, "RENAME #old #new :Typo fix"}, 250
  end
end
