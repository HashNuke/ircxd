defmodule Ircxd.BatchTest do
  use ExUnit.Case, async: true

  alias Ircxd.Batch

  describe "parse/1" do
    test "parses batch start messages" do
      assert Batch.parse(["+b1", "chathistory", "#elixir"]) ==
               {:ok, %{ref: "b1", type: "chathistory", params: ["#elixir"], direction: :start}}
    end

    test "parses batch end messages" do
      assert Batch.parse(["-b1"]) == {:ok, %{ref: "b1", direction: :end}}
    end

    test "rejects malformed batch messages" do
      assert Batch.parse([]) == {:error, :missing_reference}
      assert Batch.parse(["+b1"]) == {:error, :missing_type}
      assert Batch.parse(["b1", "chathistory"]) == {:error, :invalid_reference}
    end
  end
end
