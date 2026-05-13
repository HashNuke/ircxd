defmodule Ircxd.MetadataTest do
  use ExUnit.Case, async: true

  alias Ircxd.Metadata

  describe "valid_key?/1" do
    test "allows current metadata key characters" do
      assert Metadata.valid_key?("profile.website")
      assert Metadata.valid_key?("example/key_name-1")
      refute Metadata.valid_key?("")
      refute Metadata.valid_key?("Profile")
      refute Metadata.valid_key?("profile emoji")
    end
  end

  describe "parse_message/1" do
    test "parses server METADATA messages" do
      assert Metadata.parse_message(["alice", "profile.website", "*", "https://example.test"]) ==
               {:ok,
                %{
                  target: "alice",
                  key: "profile.website",
                  visibility: "*",
                  value: "https://example.test"
                }}
    end
  end

  describe "parse_numeric/2" do
    test "parses key value and not-set numerics" do
      assert Metadata.parse_numeric("761", [
               "nick",
               "alice",
               "profile.website",
               "*",
               "https://example.test"
             ]) ==
               {:ok,
                %{
                  type: :key_value,
                  target: "alice",
                  key: "profile.website",
                  visibility: "*",
                  value: "https://example.test"
                }}

      assert Metadata.parse_numeric("766", ["nick", "alice", "profile.website", "key not set"]) ==
               {:ok, %{type: :key_not_set, target: "alice", key: "profile.website"}}
    end

    test "parses subscription and sync-later numerics" do
      assert Metadata.parse_numeric("770", ["nick", "website", "avatar"]) ==
               {:ok, %{type: :sub_ok, keys: ["website", "avatar"]}}

      assert Metadata.parse_numeric("771", ["nick", "website"]) ==
               {:ok, %{type: :unsub_ok, keys: ["website"]}}

      assert Metadata.parse_numeric("772", ["nick", "avatar", "website"]) ==
               {:ok, %{type: :subs, keys: ["avatar", "website"]}}

      assert Metadata.parse_numeric("774", ["nick", "#elixir", "30"]) ==
               {:ok, %{type: :sync_later, target: "#elixir", retry_after: 30}}
    end
  end
end
