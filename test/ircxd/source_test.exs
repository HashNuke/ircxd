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

  test "parses server names" do
    assert %Source{raw: "irc.example.test", type: :server, server: "irc.example.test"} =
             Source.parse("irc.example.test")
  end
end
