defmodule Ircxd.MultilineTest do
  use ExUnit.Case, async: true

  alias Ircxd.Multiline

  describe "combine/1" do
    test "joins lines with newlines unless the concat tag is present" do
      lines = [
        %{body: "hello", concat?: false},
        %{body: "", concat?: false},
        %{body: "how is ", concat?: false},
        %{body: "everyone?", concat?: true}
      ]

      assert Multiline.combine(lines) == "hello\n\nhow is everyone?"
    end
  end

  describe "split/1" do
    test "splits text into multiline batch message lines" do
      assert Multiline.split("hello\n\nhow is everyone?") == [
               %{body: "hello", concat?: false},
               %{body: "", concat?: false},
               %{body: "how is everyone?", concat?: false}
             ]
    end
  end
end
