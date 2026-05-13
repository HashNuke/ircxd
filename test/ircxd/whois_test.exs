defmodule Ircxd.WhoisTest do
  use ExUnit.Case, async: true

  alias Ircxd.Whois

  test "parses WHOIS user replies" do
    assert %{nick: "nick", username: "user", host: "host", realname: "Real Name"} =
             Whois.parse_user(["me", "nick", "user", "host", "*", "Real Name"])
  end

  test "parses WHOIS channel, account, idle and end replies" do
    assert %{nick: "nick", channels: ["@#ops", "+#voice"]} =
             Whois.parse_channels(["me", "nick", "@#ops +#voice"])

    assert %{nick: "nick", account: "acct"} =
             Whois.parse_account(["me", "nick", "acct", "is logged in as"])

    assert %{nick: "nick", idle_seconds: 12, signon: 1234} =
             Whois.parse_idle(["me", "nick", "12", "1234"])

    assert %{nick: "nick"} = Whois.parse_end(["me", "nick", "End of WHOIS"])
  end
end
