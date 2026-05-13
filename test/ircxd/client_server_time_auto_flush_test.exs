defmodule Ircxd.ClientServerTimeAutoFlushTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "optionally auto-flushes server-time events in timestamp order" do
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
               "@time=2026-05-13T07:00:00.000Z :alice!a@example.test PRIVMSG #elixir :first",
               "@time=2026-05-13T07:00:01.000Z :alice!a@example.test PRIVMSG #elixir :second"
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
        caps: ["server-time"],
        server_time_order: [flush_after: 25],
        notify: self()
      )

    refute_receive {:ircxd, {:privmsg, _payload}}, 10

    assert next_privmsg_body() == "first"
    assert next_privmsg_body() == "second"
    assert next_privmsg_body() == "third"
  end

  defp next_privmsg_body do
    receive do
      {:ircxd, {:privmsg, %{body: body}}} -> body
      {:ircxd, _event} -> next_privmsg_body()
      _other -> next_privmsg_body()
    after
      1_000 -> flunk("timed out waiting for privmsg")
    end
  end
end
