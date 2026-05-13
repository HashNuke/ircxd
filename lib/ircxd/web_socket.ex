defmodule Ircxd.WebSocket do
  @moduledoc """
  Helpers for the IRCv3 WebSocket transport conventions.

  The WebSocket spec carries one IRC line per WebSocket message without the
  trailing CRLF used by TCP transports.

  Socket lifecycle is intentionally delegated to adapter modules implementing
  `Ircxd.WebSocket.Adapter`, so host applications can use Phoenix Channels or
  another WebSocket stack without forcing that dependency into this library.
  """

  alias Ircxd.Message

  @binary_subprotocol "binary.ircv3.net"
  @text_subprotocol "text.ircv3.net"

  def binary_subprotocol, do: @binary_subprotocol
  def text_subprotocol, do: @text_subprotocol

  def subprotocols(preferences \\ [:binary, :text]) do
    Enum.map(preferences, fn
      :binary -> @binary_subprotocol
      :text -> @text_subprotocol
      subprotocol when is_binary(subprotocol) -> subprotocol
    end)
  end

  def encode_line(message_or_line, mode \\ :text)

  def encode_line(%Message{} = message, mode) do
    message
    |> Message.serialize()
    |> encode_line(mode)
  end

  def encode_line(line, mode) when is_binary(line) and mode in [:binary, :text] do
    line = strip_crlf(line)

    with :ok <- validate_single_line(line),
         :ok <- validate_size(line),
         :ok <- validate_mode(line, mode) do
      {:ok, line}
    end
  end

  def decode_message(payload, mode \\ :text)

  def decode_message(payload, mode) when is_binary(payload) and mode in [:binary, :text] do
    with :ok <- validate_single_line(payload),
         :ok <- validate_size(payload),
         :ok <- validate_mode(payload, mode) do
      Message.parse(payload)
    end
  end

  def send_frame(adapter, adapter_state, message_or_line, mode \\ :text) do
    with {:ok, payload} <- encode_line(message_or_line, mode) do
      adapter.send_frame(adapter_state, mode, payload)
    end
  end

  def close(adapter, adapter_state, reason) do
    if function_exported?(adapter, :close, 2) do
      adapter.close(adapter_state, reason)
    else
      {:error, :unsupported_close}
    end
  end

  defp strip_crlf(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp validate_single_line(line) do
    if String.contains?(line, ["\r", "\n"]) do
      {:error, :not_single_line}
    else
      :ok
    end
  end

  defp validate_size(line) do
    if Message.valid_wire_size?(line <> "\r\n") do
      :ok
    else
      {:error, :line_too_long}
    end
  end

  defp validate_mode(line, :text) do
    if String.valid?(line), do: :ok, else: {:error, :invalid_utf8}
  end

  defp validate_mode(_line, :binary), do: :ok
end
