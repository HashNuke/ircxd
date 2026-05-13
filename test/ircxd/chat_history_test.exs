defmodule Ircxd.ChatHistoryTest do
  use ExUnit.Case, async: true

  alias Ircxd.ChatHistory

  describe "ref/1" do
    test "formats timestamp, msgid, and latest references" do
      assert ChatHistory.ref(:latest) == "*"

      assert ChatHistory.ref({:timestamp, "2026-05-13T07:00:00.000Z"}) ==
               "timestamp=2026-05-13T07:00:00.000Z"

      assert ChatHistory.ref({:msgid, "abc123"}) == "msgid=abc123"
    end
  end

  describe "params/1" do
    test "builds CHATHISTORY query params" do
      assert ChatHistory.params({:latest, "#elixir", :latest, 50}) ==
               ["LATEST", "#elixir", "*", "50"]

      assert ChatHistory.params({:before, "#elixir", {:msgid, "abc123"}, 25}) ==
               ["BEFORE", "#elixir", "msgid=abc123", "25"]

      assert ChatHistory.params(
               {:between, "#elixir", {:timestamp, "2026-05-13T07:00:00.000Z"},
                {:timestamp, "2026-05-13T08:00:00.000Z"}, 100}
             ) ==
               [
                 "BETWEEN",
                 "#elixir",
                 "timestamp=2026-05-13T07:00:00.000Z",
                 "timestamp=2026-05-13T08:00:00.000Z",
                 "100"
               ]

      assert ChatHistory.params(
               {:targets, {:timestamp, "2026-05-13T07:00:00.000Z"},
                {:timestamp, "2026-05-13T08:00:00.000Z"}, 25}
             ) ==
               [
                 "TARGETS",
                 "timestamp=2026-05-13T07:00:00.000Z",
                 "timestamp=2026-05-13T08:00:00.000Z",
                 "25"
               ]
    end
  end

  test "parses CHATHISTORY TARGETS returned messages" do
    assert ChatHistory.parse_targets(["#elixir", "2026-05-13T08:00:00.000Z"]) ==
             {:ok, %{target: "#elixir", latest_timestamp: "2026-05-13T08:00:00.000Z"}}
  end
end
