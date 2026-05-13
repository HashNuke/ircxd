defmodule Ircxd.NamesTest do
  use ExUnit.Case, async: true

  alias Ircxd.Names

  test "parses NAMES prefixes" do
    assert [
             %{nick: "owner", prefixes: ["~"]},
             %{nick: "op", prefixes: ["@"]},
             %{nick: "voice", prefixes: ["+"]},
             %{nick: "plain", prefixes: []}
           ] = Names.parse_names("~owner @op +voice plain")
  end

  test "parses userhost-in-names entries" do
    assert [
             %{
               nick: "owner",
               prefixes: ["~"],
               user: "own",
               host: "example.test",
               raw_source: "owner!own@example.test"
             },
             %{
               nick: "plain",
               prefixes: [],
               user: "p",
               host: "example.test",
               raw_source: "plain!p@example.test"
             }
           ] = Names.parse_names("~owner!own@example.test plain!p@example.test")
  end
end
