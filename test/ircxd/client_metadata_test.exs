defmodule Ircxd.ClientMetadataTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends METADATA commands and emits metadata messages and numerics" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :metadata=max-subs=10,max-keys=20"]

           "CAP REQ metadata", _state ->
             [":irc.test CAP * ACK :metadata"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "METADATA alice profile.website * :https://example.test",
               ":irc.test 761 nick alice profile.website * :https://example.test",
               ":irc.test 766 nick alice missing :key not set",
               ":irc.test 770 nick profile.website avatar",
               ":irc.test 771 nick avatar",
               ":irc.test 772 nick profile.website",
               ":irc.test 774 nick #elixir 30"
             ]

           "METADATA alice GET profile.website avatar", _state ->
             []

           "METADATA * SUB profile.website", _state ->
             []

           "METADATA * UNSUB profile.website", _state ->
             []

           "METADATA alice SET profile.website https://new.example.test", _state ->
             []

           "METADATA alice SET profile.website", _state ->
             []

           "METADATA alice SYNC", _state ->
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
        caps: ["metadata"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:metadata,
                     %{
                       target: "alice",
                       key: "profile.website",
                       visibility: "*",
                       value: "https://example.test"
                     }}},
                   1_000

    assert_receive {:ircxd, {:metadata_reply, %{type: :key_value, key: "profile.website"}}}, 1_000
    assert_receive {:ircxd, {:metadata_reply, %{type: :key_not_set, key: "missing"}}}, 1_000

    assert_receive {:ircxd,
                    {:metadata_reply, %{type: :sub_ok, keys: ["profile.website", "avatar"]}}},
                   1_000

    assert_receive {:ircxd, {:metadata_reply, %{type: :unsub_ok, keys: ["avatar"]}}}, 1_000
    assert_receive {:ircxd, {:metadata_reply, %{type: :subs, keys: ["profile.website"]}}}, 1_000

    assert_receive {:ircxd,
                    {:metadata_reply, %{type: :sync_later, target: "#elixir", retry_after: 30}}},
                   1_000

    assert :ok = Ircxd.Client.metadata_get(client, "alice", ["profile.website", "avatar"])
    assert_receive {:scripted_irc_line, "METADATA alice GET profile.website avatar"}, 1_000

    assert :ok = Ircxd.Client.metadata_sub(client, ["profile.website"])
    assert_receive {:scripted_irc_line, "METADATA * SUB profile.website"}, 1_000

    assert :ok = Ircxd.Client.metadata_unsub(client, "profile.website")
    assert_receive {:scripted_irc_line, "METADATA * UNSUB profile.website"}, 1_000

    assert :ok =
             Ircxd.Client.metadata_set(
               client,
               "alice",
               "profile.website",
               "https://new.example.test"
             )

    assert_receive {:scripted_irc_line,
                    "METADATA alice SET profile.website https://new.example.test"},
                   1_000

    assert :ok = Ircxd.Client.metadata_clear_key(client, "alice", "profile.website")
    assert_receive {:scripted_irc_line, "METADATA alice SET profile.website"}, 1_000

    assert :ok = Ircxd.Client.metadata_sync(client, "alice")
    assert_receive {:scripted_irc_line, "METADATA alice SYNC"}, 1_000
  end
end
