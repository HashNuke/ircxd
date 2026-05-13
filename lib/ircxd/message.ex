defmodule Ircxd.Message do
  @moduledoc """
  Parser and serializer for IRC messages.

  Supports the modern IRC message shape, including IRCv3 message tags:

      @time=2026-05-13T00:00:00Z :nick!user@host PRIVMSG #elixir :hello
  """

  defstruct tags: %{}, source: nil, command: nil, params: []

  @max_message_bytes 512
  @max_message_bytes_without_crlf @max_message_bytes - 2
  @max_client_tag_data_bytes 4094
  @max_received_tag_section_bytes 8191
  @max_params 15

  @type t :: %__MODULE__{
          tags: %{optional(String.t()) => String.t() | true},
          source: String.t() | nil,
          command: String.t(),
          params: [String.t()]
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, atom()}
  def parse(line) when is_binary(line) do
    line = String.trim_trailing(line, "\r\n")

    with false <- line == "",
         {tags, rest} <- parse_tags(line),
         {source, rest} <- parse_source(rest),
         {command, rest} <- next_token(rest),
         false <- is_nil(command),
         true <- valid_command?(command),
         {:ok, params} <- validate_params(parse_params(rest)) do
      {:ok,
       %__MODULE__{
         tags: tags,
         source: source,
         command: String.upcase(command),
         params: params
       }}
    else
      true -> {:error, :empty}
      false -> {:error, :invalid_command}
      {:error, :too_many_params} -> {:error, :too_many_params}
      _ -> {:error, :invalid}
    end
  end

  @spec serialize(t() | {String.t(), [String.t()]} | {String.t(), [String.t()], map()}) ::
          String.t()
  def serialize(%__MODULE__{} = message) do
    [
      serialize_tags(message.tags),
      if(message.source, do: ":#{message.source} "),
      message.command,
      serialize_params(message.params),
      "\r\n"
    ]
    |> Enum.reject(&is_nil/1)
    |> IO.iodata_to_binary()
  end

  def serialize({command, params}) do
    serialize(%__MODULE__{command: command, params: params})
  end

  def serialize({command, params, tags}) do
    serialize(%__MODULE__{command: command, params: params, tags: tags})
  end

  def valid_wire_size?("@" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [tag_data, message] ->
        valid_client_tag_data_size?(tag_data) and
          byte_size(message_with_crlf(message)) <= @max_message_bytes

      [_tag_data] ->
        false
    end
  end

  def valid_wire_size?(line) when is_binary(line), do: byte_size(line) <= @max_message_bytes

  def valid_client_tag_data_size?(tag_data) when is_binary(tag_data) do
    byte_size(tag_data) <= @max_client_tag_data_bytes
  end

  def valid_received_tag_section_size?(tag_section) when is_binary(tag_section) do
    String.starts_with?(tag_section, "@") and String.ends_with?(tag_section, " ") and
      byte_size(tag_section) <= @max_received_tag_section_bytes
  end

  def valid_command?(command) when is_binary(command) do
    String.match?(command, ~r/\A([A-Za-z]+|\d{3})\z/)
  end

  def max_message_bytes, do: @max_message_bytes
  def max_message_bytes_without_crlf, do: @max_message_bytes_without_crlf
  def max_client_tag_data_bytes, do: @max_client_tag_data_bytes
  def max_received_tag_section_bytes, do: @max_received_tag_section_bytes
  def max_params, do: @max_params

  def escape_tag_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\:")
    |> String.replace(" ", "\\s")
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
  end

  def unescape_tag_value(value) when is_binary(value) do
    value
    |> String.graphemes()
    |> unescape_chars([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp parse_tags("@" <> rest) do
    {tag_string, rest} =
      case String.split(rest, " ", parts: 2) do
        [tags, rest] -> {tags, rest}
        [tags] -> {tags, ""}
      end

    tags =
      tag_string
      |> String.split(";", trim: true)
      |> Map.new(fn tag ->
        case String.split(tag, "=", parts: 2) do
          [key, value] -> {key, unescape_tag_value(value)}
          [key] -> {key, true}
        end
      end)

    {tags, String.trim_leading(rest)}
  end

  defp parse_tags(line), do: {%{}, line}

  defp parse_source(":" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [source, rest] -> {source, String.trim_leading(rest)}
      [source] -> {source, ""}
    end
  end

  defp parse_source(line), do: {nil, line}

  defp next_token(""), do: {nil, ""}

  defp next_token(line) do
    case String.split(line, " ", parts: 2, trim: true) do
      [token, rest] -> {token, String.trim_leading(rest)}
      [token] -> {token, ""}
      [] -> {nil, ""}
    end
  end

  defp parse_params(""), do: []
  defp parse_params(":" <> trailing), do: [trailing]

  defp parse_params(rest) do
    case next_token(rest) do
      {nil, _} -> []
      {param, ""} -> [param]
      {param, rest} -> [param | parse_params(rest)]
    end
  end

  defp validate_params(params) when length(params) <= @max_params, do: {:ok, params}
  defp validate_params(_params), do: {:error, :too_many_params}

  defp serialize_tags(tags) when tags == %{}, do: nil

  defp serialize_tags(tags) do
    [
      "@",
      tags
      |> Enum.map(fn
        {key, true} -> key
        {key, value} -> [key, "=", escape_tag_value(to_string(value))]
      end)
      |> Enum.intersperse(";"),
      " "
    ]
  end

  defp serialize_params([]), do: ""

  defp serialize_params(params) do
    params
    |> Enum.with_index()
    |> Enum.map(fn {param, index} ->
      param = to_string(param)

      cond do
        index == length(params) - 1 and trailing_param?(param) -> [" :", param]
        true -> [" ", param]
      end
    end)
  end

  defp trailing_param?(param),
    do: param == "" or String.contains?(param, " ") or String.starts_with?(param, ":")

  defp message_with_crlf(message) do
    if String.ends_with?(message, "\r\n"), do: message, else: message <> "\r\n"
  end

  defp unescape_chars([], acc), do: acc
  defp unescape_chars(["\\", ":" | rest], acc), do: unescape_chars(rest, [";" | acc])
  defp unescape_chars(["\\", "s" | rest], acc), do: unescape_chars(rest, [" " | acc])
  defp unescape_chars(["\\", "r" | rest], acc), do: unescape_chars(rest, ["\r" | acc])
  defp unescape_chars(["\\", "n" | rest], acc), do: unescape_chars(rest, ["\n" | acc])
  defp unescape_chars(["\\", "\\" | rest], acc), do: unescape_chars(rest, ["\\" | acc])
  defp unescape_chars(["\\", char | rest], acc), do: unescape_chars(rest, [char | acc])
  defp unescape_chars([char | rest], acc), do: unescape_chars(rest, [char | acc])
end
