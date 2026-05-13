defmodule Ircxd.StandardReplyTest do
  use ExUnit.Case, async: true

  alias Ircxd.StandardReply

  describe "parse/2" do
    test "parses FAIL, WARN, and NOTE style replies" do
      assert StandardReply.parse("FAIL", ["*", "NEED_REGISTRATION", "register first"]) ==
               {:ok,
                %{
                  type: :fail,
                  command: "*",
                  code: "NEED_REGISTRATION",
                  context: [],
                  description: "register first"
                }}

      assert StandardReply.parse("WARN", ["AUTHENTICATE", "RATE_LIMITED", "PLAIN", "slow down"]) ==
               {:ok,
                %{
                  type: :warn,
                  command: "AUTHENTICATE",
                  code: "RATE_LIMITED",
                  context: ["PLAIN"],
                  description: "slow down"
                }}

      assert StandardReply.parse("NOTE", ["*", "SERVER_NOTICE", "maintenance soon"]) ==
               {:ok,
                %{
                  type: :note,
                  command: "*",
                  code: "SERVER_NOTICE",
                  context: [],
                  description: "maintenance soon"
                }}
    end

    test "rejects malformed replies" do
      assert StandardReply.parse("FAIL", ["*", "NEED_REGISTRATION"]) ==
               {:error, :missing_description}

      assert StandardReply.parse("ERROR", ["*", "CODE", "description"]) == {:error, :invalid_type}
    end
  end
end
