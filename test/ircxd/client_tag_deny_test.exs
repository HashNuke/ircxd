defmodule Ircxd.ClientTagDenyTest do
  use ExUnit.Case, async: true

  alias Ircxd.ClientTagDeny

  test "allows all tags when the token is empty or missing" do
    refute ClientTagDeny.denied?(nil, "+typing")
    refute ClientTagDeny.denied?("", "+typing")
  end

  test "blocks specific client-only tags" do
    assert ClientTagDeny.denied?("typing,example/tag", "+typing")
    assert ClientTagDeny.denied?("typing,example/tag", "+example/tag")
    refute ClientTagDeny.denied?("typing,example/tag", "+reply")
  end

  test "supports wildcard blocks with exemptions" do
    assert ClientTagDeny.denied?("*", "+typing")
    assert ClientTagDeny.denied?("*,-reply", "+typing")
    refute ClientTagDeny.denied?("*,-reply", "+reply")
  end
end
