defmodule Ircxd.UserHostTest do
  use ExUnit.Case, async: true

  alias Ircxd.UserHost

  test "parses RPL_USERHOST reply tokens" do
    assert [
             %{
               raw: "alice*=+alice@example.test",
               nick: "alice",
               oper?: true,
               away?: false,
               username: "alice",
               host: "example.test"
             },
             %{
               raw: "bob=-bob@example.test",
               nick: "bob",
               oper?: false,
               away?: true,
               username: "bob",
               host: "example.test"
             }
           ] = UserHost.parse_replies("alice*=+alice@example.test bob=-bob@example.test")
  end

  test "keeps malformed RPL_USERHOST tokens as raw entries" do
    assert [%{raw: "bad-token"}] = UserHost.parse_replies("bad-token")
    assert [] = UserHost.parse_replies(nil)
  end
end
