defmodule Ircxd.CasemappingTest do
  use ExUnit.Case, async: true

  alias Ircxd.Casemapping

  test "normalizes ascii case mapping" do
    assert Casemapping.normalize("Nick[]\\~", :ascii) == "nick[]\\~"
  end

  test "normalizes rfc1459 case mapping" do
    assert Casemapping.normalize("Nick[]\\~", :rfc1459) == "nick{}|^"
    assert Casemapping.equal?("Nick[", "nick{", :rfc1459)
  end

  test "normalizes strict-rfc1459 case mapping" do
    assert Casemapping.normalize("Nick[]\\~", :strict_rfc1459) == "nick{}|~"
    refute Casemapping.equal?("Nick~", "nick^", :strict_rfc1459)
  end

  test "maps ISUPPORT CASEMAPPING values" do
    assert Casemapping.from_isupport("ascii") == :ascii
    assert Casemapping.from_isupport("strict-rfc1459") == :strict_rfc1459
    assert Casemapping.from_isupport("unknown") == :rfc1459
  end
end
