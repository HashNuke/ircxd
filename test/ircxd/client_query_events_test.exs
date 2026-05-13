defmodule Ircxd.ClientQueryEventsTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "emits WHO and WHOIS parsed events" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [":irc.test 001 me :Welcome"]

           "WHO #chan", _state ->
             [
               ":irc.test 352 me #chan user host irc.test nick H@ :0 Real Name",
               ":irc.test 315 me #chan :End of WHO list"
             ]

           "WHOIS nick", _state ->
             [
               ":irc.test 311 me nick user host * :Real Name",
               ":irc.test 312 me nick irc.test :Server Info",
               ":irc.test 276 me nick :has client certificate fingerprint abc123",
               ":irc.test 307 me nick :is a registered nick",
               ":irc.test 319 me nick :@#chan +#other",
               ":irc.test 330 me nick acct :is logged in as",
               ":irc.test 320 me nick :is using a secure connection",
               ":irc.test 378 me nick :is connecting from *@example.test",
               ":irc.test 317 me nick 12 1234 :seconds idle, signon time",
               ":irc.test 318 me nick :End of WHOIS list"
             ]

           "WHOWAS oldnick 2", _state ->
             [
               ":irc.test 314 me oldnick user old.example.test * :Old Real Name",
               ":irc.test 369 me oldnick :End of WHOWAS"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "me",
        username: "me",
        realname: "Me",
        notify: self()
      )

    assert_event(:registered)

    assert :ok = Ircxd.Client.who(client, "#chan")
    assert_event({:who_reply, %{nick: "nick", channel: "#chan", prefixes: ["@"]}})
    assert_event({:who_end, %{mask: "#chan"}})

    assert :ok = Ircxd.Client.whois(client, "nick")
    assert_event({:whois_user, %{nick: "nick", username: "user", realname: "Real Name"}})
    assert_event({:whois_server, %{nick: "nick", server: "irc.test", info: "Server Info"}})

    assert_event(
      {:whois_certfp, %{nick: "nick", text: "has client certificate fingerprint abc123"}}
    )

    assert_event({:whois_registered_nick, %{nick: "nick", text: "is a registered nick"}})
    assert_event({:whois_channels, %{nick: "nick", channels: ["@#chan", "+#other"]}})
    assert_event({:whois_account, %{nick: "nick", account: "acct"}})
    assert_event({:whois_special, %{nick: "nick", text: "is using a secure connection"}})
    assert_event({:whois_host, %{nick: "nick", text: "is connecting from *@example.test"}})
    assert_event({:whois_idle, %{nick: "nick", idle_seconds: 12, signon: 1234}})
    assert_event({:whois_end, %{nick: "nick"}})

    assert :ok = Ircxd.Client.whowas(client, "oldnick", 2)

    assert_event(
      {:whowas_user,
       %{nick: "oldnick", username: "user", host: "old.example.test", realname: "Old Real Name"}}
    )

    assert_event({:whowas_end, %{nick: "oldnick"}})
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
