defmodule Ircxd.ClientSetnameInviteTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends SETNAME and emits SETNAME plus invite-notify events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :setname invite-notify"]

           "CAP REQ :setname invite-notify", _state ->
             [":irc.test CAP * ACK :setname invite-notify"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":alice!a@example.test SETNAME :Alice Example",
               ":ChanServ!service@example.test INVITE bob #elixir"
             ]

           "SETNAME :New Realname", _state ->
             [":nick!n@example.test SETNAME :New Realname"]

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
        caps: ["setname", "invite-notify"],
        notify: self()
      )

    assert_receive {:ircxd, {:setname, %{nick: "alice", realname: "Alice Example"}}},
                   1_000

    assert_receive {:ircxd, {:invite, %{nick: "ChanServ", target: "bob", channel: "#elixir"}}},
                   1_000

    assert :ok = Ircxd.Client.setname(client, "New Realname")
    assert_receive {:scripted_irc_line, "SETNAME :New Realname"}, 1_000
    assert_receive {:ircxd, {:setname, %{nick: "nick", realname: "New Realname"}}}, 1_000
  end
end
