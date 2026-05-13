defmodule Ircxd.MessageTest do
  use ExUnit.Case, async: true

  alias Ircxd.Message

  test "parses IRCv2-style messages" do
    assert {:ok,
            %Message{
              tags: %{},
              source: "nick!user@example.test",
              command: "PRIVMSG",
              params: ["#elixir", "hello world"]
            }} = Message.parse(":nick!user@example.test PRIVMSG #elixir :hello world\r\n")
  end

  test "parses IRCv3 message tags" do
    assert {:ok, message} =
             Message.parse(
               "@time=2026-05-13T00:00:00.000Z;example.com/foo=hello\\sworld;flag :nick PRIVMSG #chan :hi"
             )

    assert message.tags["time"] == "2026-05-13T00:00:00.000Z"
    assert message.tags["example.com/foo"] == "hello world"
    assert message.tags["flag"] == true
    assert message.source == "nick"
    assert message.command == "PRIVMSG"
    assert message.params == ["#chan", "hi"]
  end

  test "serializes commands with trailing params" do
    assert Message.serialize({"PRIVMSG", ["#elixir", "hello world"]}) ==
             "PRIVMSG #elixir :hello world\r\n"
  end

  test "serializes common Modern IRC client commands" do
    assert Message.serialize({"JOIN", ["#elixir"]}) == "JOIN #elixir\r\n"

    assert Message.serialize({"PART", ["#elixir", "gone for now"]}) ==
             "PART #elixir :gone for now\r\n"

    assert Message.serialize({"NOTICE", ["nick", "heads up"]}) == "NOTICE nick :heads up\r\n"
    assert Message.serialize({"PING", ["irc.example.test"]}) == "PING irc.example.test\r\n"
    assert Message.serialize({"PONG", ["irc.example.test"]}) == "PONG irc.example.test\r\n"

    assert Message.serialize({"KICK", ["#elixir", "nick", "reason"]}) ==
             "KICK #elixir nick reason\r\n"

    assert Message.serialize({"MODE", ["#elixir", "+o", "nick"]}) == "MODE #elixir +o nick\r\n"
    assert Message.serialize({"QUIT", ["gone for now"]}) == "QUIT :gone for now\r\n"
  end

  test "parses source-less server messages and numeric replies" do
    assert {:ok, %Message{source: nil, command: "PING", params: ["irc.example.test"]}} =
             Message.parse("PING :irc.example.test")

    assert {:ok,
            %Message{source: "irc.example.test", command: "001", params: ["nick", "welcome"]}} =
             Message.parse(":irc.example.test 001 nick :welcome")
  end

  test "recognizes valid command tokens and wire length limits" do
    assert Message.valid_command?("PRIVMSG")
    assert Message.valid_command?("001")
    refute Message.valid_command?("BAD-COMMAND")

    assert Message.max_message_bytes() == 512
    assert Message.max_message_bytes_without_crlf() == 510
    assert Message.valid_wire_size?(String.duplicate("a", 510) <> "\r\n")
    refute Message.valid_wire_size?(String.duplicate("a", 511) <> "\r\n")
  end

  test "rejects invalid command tokens while parsing" do
    assert Message.parse("BAD-COMMAND #chan :hello") == {:error, :invalid_command}
    assert Message.parse("12 PRIVMSG #chan :hello") == {:error, :invalid_command}
  end

  test "enforces the Modern IRC parameter limit" do
    params = Enum.map(1..15, &"p#{&1}") |> Enum.join(" ")
    too_many_params = Enum.map(1..16, &"p#{&1}") |> Enum.join(" ")

    assert {:ok, %Message{params: parsed_params}} = Message.parse("COMMAND #{params}")
    assert length(parsed_params) == 15
    assert Message.parse("COMMAND #{too_many_params}") == {:error, :too_many_params}
  end

  test "recognizes IRCv3 message-tag size limits separately from the message body" do
    tag_data = String.duplicate("a", 4094)
    received_tag_data = String.duplicate("a", 8189)

    assert Message.valid_client_tag_data_size?(tag_data)
    refute Message.valid_client_tag_data_size?(tag_data <> "a")

    assert Message.valid_received_tag_section_size?("@" <> received_tag_data <> " ")
    refute Message.valid_received_tag_section_size?("@" <> received_tag_data <> "a ")

    assert Message.valid_wire_size?("PRIVMSG #chan :hello\r\n")
    assert Message.valid_wire_size?("@" <> tag_data <> " PRIVMSG #chan :hello\r\n")
    refute Message.valid_wire_size?("@" <> tag_data <> "a PRIVMSG #chan :hello\r\n")
  end

  test "escapes and unescapes tag values" do
    value = "semi; space cr\r lf\n slash\\"
    escaped = Message.escape_tag_value(value)

    assert escaped == "semi\\:\\sspace\\scr\\r\\slf\\n\\sslash\\\\"
    assert Message.unescape_tag_value(escaped) == value
  end

  test "keeps the final value when duplicate IRCv3 tags are received" do
    assert {:ok, %Message{tags: %{"time" => "final"}}} =
             Message.parse("@time=old;time=final PRIVMSG #chan :hello")
  end
end
