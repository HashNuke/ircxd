defmodule Ircxd.WhoisTest do
  use ExUnit.Case, async: true

  alias Ircxd.Whois

  test "parses WHOIS user replies" do
    assert %{nick: "nick", username: "user", host: "host", realname: "Real Name"} =
             Whois.parse_user(["me", "nick", "user", "host", "*", "Real Name"])

    assert %{nick: "oldnick", username: "user", host: "host", realname: "Old Real Name"} =
             Whois.parse_whowas_user(["me", "oldnick", "user", "host", "*", "Old Real Name"])
  end

  test "parses WHOIS channel, account, idle and end replies" do
    assert %{nick: "nick", channels: ["@#ops", "+#voice"]} =
             Whois.parse_channels(["me", "nick", "@#ops +#voice"])

    assert %{nick: "nick", text: "has client certificate fingerprint abc123"} =
             Whois.parse_certfp(["me", "nick", "has client certificate fingerprint abc123"])

    assert %{nick: "nick", text: "is a registered nick"} =
             Whois.parse_registered_nick(["me", "nick", "is a registered nick"])

    assert %{nick: "nick", account: "acct"} =
             Whois.parse_account(["me", "nick", "acct", "is logged in as"])

    assert %{nick: "nick", text: "is using a secure connection"} =
             Whois.parse_special(["me", "nick", "is using a secure connection"])

    assert %{nick: "nick", text: "is connecting from *@example.test"} =
             Whois.parse_host(["me", "nick", "is connecting from *@example.test"])

    assert %{nick: "nick", text: "actually using host real.example.test"} =
             Whois.parse_actual_host(["me", "nick", "actually using host real.example.test"])

    assert %{nick: "nick", modes: ["+i", "+w"]} =
             Whois.parse_modes(["me", "nick", "+i +w"])

    assert %{nick: "nick", text: "is using a secure connection"} =
             Whois.parse_secure(["me", "nick", "is using a secure connection"])

    assert %{nick: "nick", idle_seconds: 12, signon: 1234} =
             Whois.parse_idle(["me", "nick", "12", "1234"])

    assert %{nick: "nick"} = Whois.parse_end(["me", "nick", "End of WHOIS"])
    assert %{nick: "oldnick"} = Whois.parse_whowas_end(["me", "oldnick", "End of WHOWAS"])
  end
end
