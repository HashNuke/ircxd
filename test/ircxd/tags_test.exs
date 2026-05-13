defmodule Ircxd.TagsTest do
  use ExUnit.Case, async: true

  alias Ircxd.Message
  alias Ircxd.Tags

  test "parses server-time tags" do
    message = %Message{tags: %{"time" => "2026-05-13T07:30:00.123Z"}}

    assert {:ok, datetime} = Tags.server_time(message)
    assert datetime.year == 2026
    assert datetime.microsecond == {123_000, 3}
  end

  test "extracts msgid and label tags" do
    message = %Message{tags: %{"msgid" => "abc", "label" => "request-1"}}

    assert Tags.msgid(message) == "abc"
    assert Tags.label(message) == "request-1"
  end

  test "extracts account tags" do
    assert Tags.account(%Message{tags: %{"account" => "alice"}}) == "alice"
    assert Tags.account(%Message{tags: %{"account" => "*"}}) == nil
  end
end
