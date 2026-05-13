defmodule Ircxd.ClientNoImplicitNamesTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "requests no-implicit-names and can explicitly send NAMES" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :no-implicit-names"]

           "CAP REQ no-implicit-names", _state ->
             [":irc.test CAP * ACK :no-implicit-names"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "JOIN #chan", _state ->
             [":nick!user@host JOIN #chan"]

           "NAMES #chan", _state ->
             [
               ":irc.test 353 nick = #chan :@nick alice",
               ":irc.test 366 nick #chan :End of /NAMES list"
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
        caps: ["no-implicit-names"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok = Ircxd.Client.join(client, "#chan")
    assert_receive {:ircxd, {:join, %{nick: "nick", channel: "#chan"}}}, 1_000
    refute_receive {:ircxd, {:names, %{channel: "#chan"}}}, 250

    assert :ok = Ircxd.Client.names(client, "#chan")
    assert_receive {:scripted_irc_line, "NAMES #chan"}, 1_000

    assert_receive {:ircxd, {:names, %{channel: "#chan", names: [%{nick: "nick"} | _]}}},
                   1_000

    assert_receive {:ircxd, {:names_end, %{channel: "#chan"}}}, 1_000
  end
end
