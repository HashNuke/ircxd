defmodule Ircxd.Formatting do
  @moduledoc """
  Parser helpers for common IRC formatting control codes.

  The parser returns text spans with compact style maps. Rendering is left to
  the host application.
  """

  @type style :: %{
          optional(:bold) => true,
          optional(:italic) => true,
          optional(:underline) => true,
          optional(:strikethrough) => true,
          optional(:monospace) => true,
          optional(:reverse) => true,
          optional(:foreground) => String.t(),
          optional(:background) => String.t(),
          optional(:hex_foreground) => String.t(),
          optional(:hex_background) => String.t()
        }

  @type span :: %{text: String.t(), style: style()}

  @bold 0x02
  @color 0x03
  @hex_color 0x04
  @reset 0x0F
  @monospace 0x11
  @reverse 0x16
  @italic 0x1D
  @strikethrough 0x1E
  @underline 0x1F

  @default_style %{
    bold: false,
    italic: false,
    underline: false,
    strikethrough: false,
    monospace: false,
    reverse: false,
    foreground: nil,
    background: nil,
    hex_foreground: nil,
    hex_background: nil
  }

  @spec parse(String.t()) :: [span()]
  def parse(text) when is_binary(text) do
    text
    |> do_parse(@default_style, [], [])
    |> Enum.reverse()
  end

  @spec strip(String.t()) :: String.t()
  def strip(text) when is_binary(text) do
    text
    |> parse()
    |> Enum.map_join(& &1.text)
  end

  defp do_parse(<<>>, style, buffer, spans), do: flush_span(buffer, style, spans)

  defp do_parse(<<@bold, rest::binary>>, style, buffer, spans) do
    continue(rest, style, toggle(style, :bold), buffer, spans)
  end

  defp do_parse(<<@italic, rest::binary>>, style, buffer, spans) do
    continue(rest, style, toggle(style, :italic), buffer, spans)
  end

  defp do_parse(<<@underline, rest::binary>>, style, buffer, spans) do
    continue(rest, style, toggle(style, :underline), buffer, spans)
  end

  defp do_parse(<<@strikethrough, rest::binary>>, style, buffer, spans) do
    continue(rest, style, toggle(style, :strikethrough), buffer, spans)
  end

  defp do_parse(<<@monospace, rest::binary>>, style, buffer, spans) do
    continue(rest, style, toggle(style, :monospace), buffer, spans)
  end

  defp do_parse(<<@reverse, rest::binary>>, style, buffer, spans) do
    continue(rest, style, toggle(style, :reverse), buffer, spans)
  end

  defp do_parse(<<@reset, rest::binary>>, style, buffer, spans) do
    continue(rest, style, @default_style, buffer, spans)
  end

  defp do_parse(<<@color, rest::binary>>, style, buffer, spans) do
    {rest, new_style} = parse_color(rest, style)
    continue(rest, style, new_style, buffer, spans)
  end

  defp do_parse(<<@hex_color, rest::binary>>, style, buffer, spans) do
    {rest, new_style} = parse_hex_color(rest, style)
    continue(rest, style, new_style, buffer, spans)
  end

  defp do_parse(<<char::utf8, rest::binary>>, style, buffer, spans) do
    do_parse(rest, style, [<<char::utf8>> | buffer], spans)
  end

  defp continue(rest, old_style, new_style, buffer, spans) do
    spans = flush_span(buffer, old_style, spans)
    do_parse(rest, new_style, [], spans)
  end

  defp flush_span([], _style, spans), do: spans

  defp flush_span(buffer, style, spans) do
    [
      %{text: buffer |> Enum.reverse() |> IO.iodata_to_binary(), style: compact_style(style)}
      | spans
    ]
  end

  defp compact_style(style) do
    style
    |> Enum.reject(fn {_key, value} -> value in [false, nil] end)
    |> Map.new()
  end

  defp toggle(style, key), do: Map.update!(style, key, &(!&1))

  defp parse_color(rest, style) do
    case take_digits(rest, 2) do
      {nil, rest} ->
        {rest, reset_numeric_colors(style)}

      {foreground, rest} ->
        {background, rest} = take_optional_background(rest, 2)

        style =
          style
          |> Map.put(:foreground, foreground)
          |> Map.put(:background, background || style.background)
          |> Map.put(:hex_foreground, nil)
          |> Map.put(:hex_background, nil)

        {rest, style}
    end
  end

  defp parse_hex_color(rest, style) do
    case take_hex(rest, 6) do
      {nil, rest} ->
        {rest, reset_numeric_colors(style)}

      {foreground, rest} ->
        {background, rest} = take_optional_hex_background(rest)

        style =
          style
          |> Map.put(:hex_foreground, String.upcase(foreground))
          |> Map.put(:hex_background, background && String.upcase(background))
          |> Map.put(:foreground, nil)
          |> Map.put(:background, nil)

        {rest, style}
    end
  end

  defp reset_numeric_colors(style) do
    %{style | foreground: nil, background: nil, hex_foreground: nil, hex_background: nil}
  end

  defp take_optional_background(<<?,, rest::binary>> = original, max_digits) do
    case take_digits(rest, max_digits) do
      {nil, _rest} -> {nil, original}
      {background, rest} -> {background, rest}
    end
  end

  defp take_optional_background(rest, _max_digits), do: {nil, rest}

  defp take_optional_hex_background(<<?,, rest::binary>> = original) do
    case take_hex(rest, 6) do
      {nil, _rest} -> {nil, original}
      {background, rest} -> {background, rest}
    end
  end

  defp take_optional_hex_background(rest), do: {nil, rest}

  defp take_digits(rest, max) do
    {digits, rest} = take_while(rest, max, &digit?/1)
    if digits == "", do: {nil, rest}, else: {digits, rest}
  end

  defp take_hex(rest, count) do
    {hex, remaining} = take_while(rest, count, &hex?/1)

    if String.length(hex) == count do
      {hex, remaining}
    else
      {nil, rest}
    end
  end

  defp take_while(rest, 0, _fun), do: {"", rest}

  defp take_while(<<char, rest::binary>>, remaining, fun) do
    if fun.(char) do
      {chars, rest} = take_while(rest, remaining - 1, fun)
      {<<char>> <> chars, rest}
    else
      {"", <<char, rest::binary>>}
    end
  end

  defp take_while(<<>>, _remaining, _fun), do: {"", ""}

  defp digit?(char), do: char in ?0..?9

  defp hex?(char), do: digit?(char) or char in ?a..?f or char in ?A..?F
end
