defmodule Ircxd.ClientMetadataBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "aggregates draft metadata batch replies including standard FAIL entries" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch draft/metadata-2"]

           "CAP REQ :batch draft/metadata-2", _state ->
             [":irc.test CAP * ACK :batch draft/metadata-2"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "BATCH +meta1 metadata alice",
               "@batch=meta1 :irc.test 761 nick alice profile.website * :https://example.test",
               "@batch=meta1 :irc.test 766 nick alice missing :key not set",
               "@batch=meta1 FAIL METADATA KEY_INVALID bad_key :That is not a valid key",
               "BATCH -meta1"
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
        caps: ["batch", "draft/metadata-2"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:metadata_batch,
                     %{
                       ref: "meta1",
                       target: "alice",
                       entries: [
                         {:metadata_reply, %{type: :key_value, key: "profile.website"}},
                         {:metadata_reply, %{type: :key_not_set, key: "missing"}},
                         {:standard_reply,
                          %{type: :fail, command: "METADATA", code: "KEY_INVALID"}}
                       ]
                     }}},
                   1_000
  end
end
