defmodule Ircxd.ClientServerTimeOrderTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "optionally buffers server-time events and flushes them in timestamp order" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :server-time"]

           "CAP REQ server-time", _state ->
             [":irc.test CAP * ACK :server-time"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@time=2026-05-13T07:00:02.000Z :alice!a@example.test PRIVMSG #elixir :third",
               "@time=2026-05-13T07:00:01.000Z :alice!a@example.test PRIVMSG #elixir :second",
               "@time=2026-05-13T07:00:00.000Z :alice!a@example.test PRIVMSG #elixir :first"
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
        caps: ["server-time"],
        server_time_order: :manual,
        notify: self()
      )

    refute_receive {:ircxd, {:privmsg, _payload}}, 100

    assert :ok = Ircxd.Client.flush_server_time(client)

    assert_receive {:ircxd, {:privmsg, %{body: "first"}}}, 1_000
    assert_receive {:ircxd, {:privmsg, %{body: "second"}}}, 1_000
    assert_receive {:ircxd, {:privmsg, %{body: "third"}}}, 1_000
  end
end
