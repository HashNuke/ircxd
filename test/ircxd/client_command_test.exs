defmodule Ircxd.ClientCommandTest do
  use ExUnit.Case, async: true

  alias Ircxd.ClientCommand
  alias Ircxd.Message

  test "parses client command parameters without losing trailing values" do
    assert {:ok, %Message{command: "TOPIC", params: ["#room"]}} =
             ClientCommand.parse("TOPIC #room")

    assert {:ok, %Message{command: "TOPIC", params: ["#room", ""]}} =
             ClientCommand.parse("TOPIC #room :")

    assert {:ok, %Message{command: "TOPIC", params: ["#room", "A topic with spaces"]}} =
             ClientCommand.parse("topic #room :A topic with spaces")

    assert {:ok, %Message{command: "PART", params: ["#room", "good night"]}} =
             ClientCommand.parse("PART #room :good night")
  end

  test "enforces the client parameter and wire-size limits" do
    fifteen = Enum.map_join(1..15, " ", &"p#{&1}")
    sixteen = fifteen <> " p16"

    assert {:ok, %Message{params: params}} = ClientCommand.parse("VENDOR #{fifteen}")
    assert length(params) == 15
    assert {:error, :too_many_params} = ClientCommand.parse("VENDOR #{sixteen}")

    assert {:error, :line_too_long} =
             ClientCommand.parse("PRIVMSG #room :" <> String.duplicate("x", 512))
  end

  test "rejects injection characters before parsing" do
    assert {:error, :line_break_not_allowed} =
             ClientCommand.parse("PRIVMSG #room :one\r\nOPER root secret")

    assert {:error, :nul_not_allowed} = ClientCommand.parse("PRIVMSG #room :one\0two")
  end

  test "forbids server-only forms and tags by default with explicit opt-ins" do
    assert {:error, :source_not_allowed} =
             ClientCommand.parse(":spoofed.example PRIVMSG #room :hello")

    assert {:error, :numeric_command_not_allowed} =
             ClientCommand.parse("318 me alice :End of WHOIS")

    assert {:error, :tags_not_allowed} = ClientCommand.parse("@label=req-1 WHOIS alice")

    assert {:ok, %Message{source: "trusted.example"}} =
             ClientCommand.parse(":trusted.example NOTICE me :hello", source: :allow)

    assert {:ok, %Message{command: "318"}} =
             ClientCommand.parse("318 me alice :End", numerics: :allow)

    assert {:ok, %Message{tags: %{"label" => "req-1"}}} =
             ClientCommand.parse("@label=req-1 WHOIS alice", tags: :allow)
  end

  test "validates enabled client tags and label constraints" do
    assert {:error, :invalid_tag_key} =
             ClientCommand.parse("@bad!tag=value WHOIS alice", tags: :allow)

    assert {:error, :invalid_tag_value} =
             ClientCommand.validate(
               %Message{command: "TAGMSG", params: ["#room"], tags: %{"+example/tag" => <<0>>}},
               tags: :allow
             )

    assert {:error, :invalid_label} =
             ClientCommand.parse("@label=" <> String.duplicate("a", 65) <> " WHOIS alice",
               tags: :allow
             )
  end

  test "rejects programmatic messages whose middle parameters do not round trip" do
    for params <- [
          ["", "hello"],
          ["#room extra", "hello"],
          [":#room", "hello"]
        ] do
      assert {:error, :invalid_param} =
               ClientCommand.validate(%Message{command: "PRIVMSG", params: params})
    end

    assert :ok =
             ClientCommand.validate(%Message{command: "PRIVMSG", params: ["#room", ""]})

    assert :ok =
             ClientCommand.validate(%Message{
               command: "PRIVMSG",
               params: ["#room", "body with spaces"]
             })
  end

  test "validates an explicitly allowed source as one injection-safe token" do
    for source <- ["", "server name", ":server", "server\r\nOPER root secret", <<0>>] do
      assert {:error, :invalid_source} =
               ClientCommand.validate(
                 %Message{source: source, command: "NOTICE", params: ["nick", "hello"]},
                 source: :allow
               )
    end

    assert :ok =
             ClientCommand.validate(
               %Message{
                 source: "nick!user@example.test",
                 command: "NOTICE",
                 params: ["nick", "hello"]
               },
               source: :allow
             )
  end
end
