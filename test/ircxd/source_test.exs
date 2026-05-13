defmodule Ircxd.SourceTest do
  use ExUnit.Case, async: true

  alias Ircxd.Source

  test "parses nick user host masks" do
    assert %Source{
             raw: "nick!user@example.test",
             type: :user,
             nick: "nick",
             user: "user",
             host: "example.test"
           } = Source.parse("nick!user@example.test")
  end

  test "parses partial Modern IRC user sources" do
    assert %Source{raw: "WiZ", type: :user, nick: "WiZ", user: nil, host: nil} =
             Source.parse("WiZ")

    assert %Source{raw: "dan-!d", type: :user, nick: "dan-", user: "d", host: nil} =
             Source.parse("dan-!d")

    assert %Source{raw: "val@host.test", type: :user, nick: "val", user: nil, host: "host.test"} =
             Source.parse("val@host.test")
  end

  test "parses server names" do
    assert %Source{raw: "irc.example.test", type: :server, server: "irc.example.test"} =
             Source.parse("irc.example.test")
  end
end
