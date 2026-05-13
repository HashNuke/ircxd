defmodule Ircxd.MonitorTest do
  use ExUnit.Case, async: true

  alias Ircxd.Monitor

  describe "parse_targets/1" do
    test "splits comma-delimited target lists" do
      assert Monitor.parse_targets("alice,bob") == ["alice", "bob"]
      assert Monitor.parse_targets("alice!a@example.test,bob") == ["alice!a@example.test", "bob"]
      assert Monitor.parse_targets("") == []
    end
  end

  describe "parse_numeric/2" do
    test "parses monitor online and offline numerics" do
      assert Monitor.parse_numeric("730", ["nick", "alice!a@example.test,bob"]) ==
               {:ok,
                %{
                  type: :online,
                  targets: ["alice!a@example.test", "bob"],
                  sources: [
                    %{nick: "alice", user: "a", host: "example.test"},
                    %{nick: "bob", user: nil, host: nil}
                  ]
                }}

      assert Monitor.parse_numeric("731", ["nick", "carol,dave"]) ==
               {:ok, %{type: :offline, targets: ["carol", "dave"]}}
    end

    test "parses monitor list, end, and full numerics" do
      assert Monitor.parse_numeric("732", ["nick", "alice,bob"]) ==
               {:ok, %{type: :list, targets: ["alice", "bob"]}}

      assert Monitor.parse_numeric("733", ["nick", "End of MONITOR list"]) ==
               {:ok, %{type: :list_end}}

      assert Monitor.parse_numeric("734", ["nick", "100", "alice,bob", "Monitor list is full"]) ==
               {:ok,
                %{
                  type: :list_full,
                  limit: 100,
                  targets: ["alice", "bob"],
                  description: "Monitor list is full"
                }}
    end
  end
end
