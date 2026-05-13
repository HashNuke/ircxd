defmodule Ircxd.ClientEventsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits Modern IRC state-change events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               ":old!user@host NICK :new",
               ":new!user@host JOIN :#chan",
               ":new!user@host TOPIC #chan :topic text",
               ":irc.test MODE #chan +o new",
               ":op!user@host KICK #chan new :too loud",
               ":new!user@host PART #chan :bye",
               ":new!user@host QUIT :gone",
               "ERROR :closing link"
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
        notify: self()
      )

    assert_event(:registered)
    assert_event({:nick, %{old_nick: "old", new_nick: "new"}})
    assert_event({:join, %{nick: "new", channel: "#chan"}})
    assert_event({:topic, %{nick: "new", channel: "#chan", topic: "topic text"}})
    assert_event({:mode, %{nick: "irc.test", target: "#chan", modes: "+o", params: ["new"]}})
    assert_event({:kick, %{nick: "op", channel: "#chan", target_nick: "new", reason: "too loud"}})
    assert_event({:part, %{nick: "new", channel: "#chan", reason: "bye"}})
    assert_event({:quit, %{nick: "new", reason: "gone"}})
    assert_event({:error, %{reason: "closing link"}})
  end

  defp assert_event(expected) do
    assert {:ok, _event} =
             wait_for_event(fn event ->
               if match_event?(event, expected), do: {:ok, event}, else: :cont
             end)
  end

  defp wait_for_event(fun, timeout \\ 1_000) do
    receive do
      {:ircxd, event} ->
        case fun.(event) do
          {:ok, value} -> {:ok, value}
          :cont -> wait_for_event(fun, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp match_event?(event, expected) when is_atom(expected), do: event == expected

  defp match_event?({name, payload}, {name, expected_payload}) when is_map(payload) do
    Enum.all?(expected_payload, fn {key, value} -> Map.get(payload, key) == value end)
  end

  defp match_event?(_, _), do: false
end
