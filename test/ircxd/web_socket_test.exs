defmodule Ircxd.WebSocketTest do
  use ExUnit.Case, async: true

  alias Ircxd.Message
  alias Ircxd.WebSocket

  defmodule TestAdapter do
    @behaviour Ircxd.WebSocket.Adapter

    @impl true
    def send_frame(owner, mode, payload) do
      send(owner, {:frame, mode, payload})
      :ok
    end
  end

  test "lists IRCv3 WebSocket subprotocols in preference order" do
    assert WebSocket.subprotocols() == ["binary.ircv3.net", "text.ircv3.net"]
    assert WebSocket.subprotocols([:text, :binary]) == ["text.ircv3.net", "binary.ircv3.net"]
  end

  test "encodes one IRC line per websocket message without trailing CRLF" do
    assert WebSocket.encode_line("PRIVMSG #elixir :hello\r\n", :text) ==
             {:ok, "PRIVMSG #elixir :hello"}

    assert WebSocket.encode_line(%Message{command: "PING", params: ["irc.example.test"]}, :text) ==
             {:ok, "PING irc.example.test"}
  end

  test "decodes websocket messages as IRC lines" do
    assert {:ok, %Message{command: "PRIVMSG", params: ["#elixir", "hello"]}} =
             WebSocket.decode_message("PRIVMSG #elixir :hello", :text)
  end

  test "rejects multiline websocket payloads" do
    assert WebSocket.encode_line("PRIVMSG #elixir :hello\nPRIVMSG #elixir :again", :text) ==
             {:error, :not_single_line}

    assert WebSocket.decode_message("PING one\r\nPING two", :text) ==
             {:error, :not_single_line}
  end

  test "rejects oversized websocket payloads using the IRC line limit" do
    assert WebSocket.encode_line(String.duplicate("a", Message.max_message_bytes()), :text) ==
             {:error, :line_too_long}
  end

  test "requires valid UTF-8 for text messages but allows arbitrary binary messages" do
    invalid_utf8 = <<255>>

    assert WebSocket.encode_line(invalid_utf8, :text) == {:error, :invalid_utf8}
    assert WebSocket.encode_line(invalid_utf8, :binary) == {:ok, invalid_utf8}
  end

  test "sends validated IRC websocket payloads through an adapter" do
    assert :ok =
             WebSocket.send_frame(
               TestAdapter,
               self(),
               %Message{command: "PRIVMSG", params: ["#elixir", "hello"]},
               :text
             )

    assert_receive {:frame, :text, "PRIVMSG #elixir hello"}
  end
end
