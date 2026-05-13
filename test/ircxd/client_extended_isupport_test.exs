defmodule Ircxd.ClientExtendedISupportTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "requests and aggregates draft extended-isupport batches" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch draft/extended-isupport"]

           "CAP REQ :batch draft/extended-isupport", _state ->
             [":irc.test CAP * ACK :batch draft/extended-isupport"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "ISUPPORT", _state ->
             [
               ":irc.test BATCH +is1 draft/isupport",
               "@batch=is1 :irc.test 005 * NETWORK=Example NICKLEN=30 FOO=bar",
               "@batch=is1 :irc.test 005 * CHANNELLEN=64 NICKLEN=42 -FOO",
               ":irc.test BATCH -is1"
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
        caps: ["batch", "draft/extended-isupport"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.isupport(client)
    assert_receive {:scripted_irc_line, "ISUPPORT"}, 1_000
    assert_receive {:ircxd, {:batch_start, %{ref: "is1", type: "draft/isupport"}}}, 1_000
    assert_receive {:ircxd, {:isupport, %{"NETWORK" => "Example", "NICKLEN" => "30"}}}, 1_000

    assert_receive {:ircxd,
                    {:batched,
                     %{
                       ref: "is1",
                       event: {:isupport, %{"NETWORK" => "Example", "NICKLEN" => "30"}}
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:isupport, %{"CHANNELLEN" => "64", "NICKLEN" => "42", "FOO" => false}}},
                   1_000

    assert_receive {:ircxd,
                    {:isupport_batch,
                     %{
                       ref: "is1",
                       tokens: %{
                         "NETWORK" => "Example",
                         "CHANNELLEN" => "64",
                         "NICKLEN" => "42",
                         "FOO" => false
                       },
                       entries: [
                         %{"NETWORK" => "Example", "NICKLEN" => "30", "FOO" => "bar"},
                         %{"CHANNELLEN" => "64", "NICKLEN" => "42", "FOO" => false}
                       ]
                     }}},
                   1_000

    assert_receive {:ircxd, {:batch_end, %{ref: "is1"}}}, 1_000
  end

  test "requires draft/extended-isupport before sending ISUPPORT" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state -> [":irc.test CAP * LS :batch"]
           "CAP END", _state -> [":irc.test 001 nick :Welcome"]
           _line, _state -> []
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

    assert {:error, {:capability_not_enabled, "draft/extended-isupport"}} =
             Ircxd.Client.isupport(client)
  end
end
