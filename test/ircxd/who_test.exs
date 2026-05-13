defmodule Ircxd.WhoTest do
  use ExUnit.Case, async: true

  alias Ircxd.Who

  test "parses standard WHO replies" do
    assert %{
             channel: "#chan",
             username: "user",
             host: "host",
             server: "irc.example",
             nick: "nick",
             flags: "H@",
             away?: false,
             oper?: false,
             prefixes: ["@"],
             hops: 0,
             realname: "Real Name"
           } =
             Who.parse_reply([
               "me",
               "#chan",
               "user",
               "host",
               "irc.example",
               "nick",
               "H@",
               "0 Real Name"
             ])
  end

  test "parses WHOX replies using the default ircxd field order" do
    assert %{
             channel: "#chan",
             username: "user",
             host: "host",
             server: "irc.example",
             nick: "nick",
             flags: "H",
             account: "acct",
             realname: "Real Name"
           } =
             Who.parse_whox([
               "me",
               "42",
               "#chan",
               "user",
               "host",
               "irc.example",
               "nick",
               "H",
               "acct",
               "Real Name"
             ])
  end
end
