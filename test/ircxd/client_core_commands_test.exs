defmodule Ircxd.ClientCoreCommandsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends PASS before capability negotiation when a server password is configured" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state -> [":irc.test CAP * LS :"]
           "CAP END", _state -> [":irc.test 001 nick :Welcome"]
           _line, _state -> []
         end}
      )

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        password: "server-password",
        nick: "nick",
        username: "nick",
        realname: "Nick",
        notify: self()
      )

    assert_receive {:scripted_irc_line, "PASS server-password"}, 1_000
    assert_receive {:scripted_irc_line, "CAP LS 302"}, 1_000
    assert_receive {:scripted_irc_line, "NICK nick"}, 1_000
    assert_receive {:scripted_irc_line, "USER nick 0 * Nick"}, 1_000
  end

  test "sends Modern IRC core command helpers" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state -> [":irc.test CAP * LS :"]
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

    assert :ok = Ircxd.Client.nick(client, "nick2")
    assert :ok = Ircxd.Client.list(client, ["#elixir", "#erlang"], "irc.example.test")
    assert :ok = Ircxd.Client.invite(client, "alice", "#elixir")
    assert :ok = Ircxd.Client.mode_query(client, "#elixir")
    assert :ok = Ircxd.Client.channel_modes(client, "#erlang")
    assert :ok = Ircxd.Client.user_modes(client, "nick")
    assert :ok = Ircxd.Client.mode(client, "#elixir", "+o", ["alice"])
    assert :ok = Ircxd.Client.motd(client, "irc.example.test")
    assert :ok = Ircxd.Client.version(client, "irc.example.test")
    assert :ok = Ircxd.Client.admin(client, "irc.example.test")
    assert :ok = Ircxd.Client.lusers(client, "*", "irc.example.test")
    assert :ok = Ircxd.Client.time(client, "irc.example.test")
    assert :ok = Ircxd.Client.stats(client, "u", "irc.example.test")
    assert :ok = Ircxd.Client.help(client, "list")
    assert :ok = Ircxd.Client.info(client, "irc.example.test")
    assert :ok = Ircxd.Client.links(client, "remote.example.test", "*.example.test")
    assert :ok = Ircxd.Client.userhost(client, ["alice", "bob"])
    assert :ok = Ircxd.Client.ison(client, ["alice", "bob"])
    assert :ok = Ircxd.Client.wallops(client, "network notice")
    assert :ok = Ircxd.Client.oper(client, "root", "secret")
    assert :ok = Ircxd.Client.kill(client, "badnick", "bad behavior")
    assert :ok = Ircxd.Client.squery(client, "NickServ", "HELP")
    assert :ok = Ircxd.Client.trace(client, "irc.example.test")

    assert :ok =
             Ircxd.Client.connect_server(client, "irc2.example.test", 7000, "irc.example.test")

    assert :ok = Ircxd.Client.squit(client, "irc2.example.test", "maintenance")
    assert :ok = Ircxd.Client.rehash(client)
    assert :ok = Ircxd.Client.restart(client)
    assert :ok = Ircxd.Client.summon(client, "alice", "irc.example.test", "#elixir")
    assert :ok = Ircxd.Client.users(client, "irc.example.test")
    assert :ok = Ircxd.Client.servlist(client, "*Serv", "0")

    assert_receive {:scripted_irc_line, "NICK nick2"}, 1_000
    assert_receive {:scripted_irc_line, "LIST #elixir,#erlang irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "INVITE alice #elixir"}, 1_000
    assert_receive {:scripted_irc_line, "MODE #elixir"}, 1_000
    assert_receive {:scripted_irc_line, "MODE #erlang"}, 1_000
    assert_receive {:scripted_irc_line, "MODE nick"}, 1_000
    assert_receive {:scripted_irc_line, "MODE #elixir +o alice"}, 1_000
    assert_receive {:scripted_irc_line, "MOTD irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "VERSION irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "ADMIN irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "LUSERS * irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "TIME irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "STATS u irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "HELP list"}, 1_000
    assert_receive {:scripted_irc_line, "INFO irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "LINKS remote.example.test *.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "USERHOST alice bob"}, 1_000
    assert_receive {:scripted_irc_line, "ISON alice bob"}, 1_000
    assert_receive {:scripted_irc_line, "WALLOPS :network notice"}, 1_000
    assert_receive {:scripted_irc_line, "OPER root secret"}, 1_000
    assert_receive {:scripted_irc_line, "KILL badnick :bad behavior"}, 1_000
    assert_receive {:scripted_irc_line, "SQUERY NickServ HELP"}, 1_000
    assert_receive {:scripted_irc_line, "TRACE irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "CONNECT irc2.example.test 7000 irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "SQUIT irc2.example.test maintenance"}, 1_000
    assert_receive {:scripted_irc_line, "REHASH"}, 1_000
    assert_receive {:scripted_irc_line, "RESTART"}, 1_000
    assert_receive {:scripted_irc_line, "SUMMON alice irc.example.test #elixir"}, 1_000
    assert_receive {:scripted_irc_line, "USERS irc.example.test"}, 1_000
    assert_receive {:scripted_irc_line, "SERVLIST *Serv 0"}, 1_000
  end
end
