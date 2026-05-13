defmodule Ircxd.ISupport do
  @moduledoc """
  Parser for `RPL_ISUPPORT` (`005`) tokens.
  """

  def parse_params(params) when is_list(params) do
    params
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "are supported by this server"))
    |> Map.new(&parse_token/1)
  end

  def parse_token("-" <> key), do: {key, false}

  def parse_token(token) do
    case String.split(token, "=", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, true}
    end
  end

  def prefix_modes(isupport) when is_map(isupport) do
    case Map.get(isupport, "PREFIX", "(ov)@+") do
      value when value in [true, false] ->
        []

      "(" <> rest ->
        with [modes, prefixes] <- String.split(rest, ")", parts: 2),
             true <- String.length(modes) == String.length(prefixes) do
          modes
          |> String.graphemes()
          |> Enum.zip(String.graphemes(prefixes))
          |> Enum.map(fn {mode, prefix} -> %{mode: mode, prefix: prefix} end)
        else
          _ -> []
        end

      _value ->
        []
    end
  end

  def chanmodes(isupport) when is_map(isupport) do
    parts =
      isupport
      |> Map.get("CHANMODES", "")
      |> string_value()
      |> String.split(",", trim: false)

    %{
      type_a: Enum.at(parts, 0, ""),
      type_b: Enum.at(parts, 1, ""),
      type_c: Enum.at(parts, 2, ""),
      type_d: Enum.at(parts, 3, ""),
      extra: Enum.drop(parts, 4)
    }
  end

  def chanlimit(isupport) when is_map(isupport) do
    isupport
    |> Map.get("CHANLIMIT", "")
    |> parse_pair_list()
    |> Enum.flat_map(fn {prefixes, limit} ->
      prefixes
      |> String.graphemes()
      |> Enum.map(&{&1, limit})
    end)
    |> Map.new()
  end

  def maxlist(isupport) when is_map(isupport) do
    isupport
    |> Map.get("MAXLIST", "")
    |> parse_pair_list()
    |> Map.new()
  end

  def targmax(isupport) when is_map(isupport) do
    isupport
    |> Map.get("TARGMAX", "")
    |> parse_pair_list()
    |> Map.new(fn {command, limit} -> {String.upcase(command), limit} end)
  end

  def integer(isupport, key, default \\ nil) when is_map(isupport) and is_binary(key) do
    case Map.fetch(isupport, key) do
      {:ok, value} -> parse_integer_value(value, default)
      :error -> default
    end
  end

  def characters(isupport, key) when is_map(isupport) and is_binary(key) do
    isupport
    |> Map.get(key, "")
    |> string_value()
    |> String.graphemes()
  end

  def enabled?(isupport, key) when is_map(isupport) and is_binary(key) do
    case Map.fetch(isupport, key) do
      {:ok, false} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  defp parse_pair_list(value) do
    value
    |> string_value()
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn item ->
      case String.split(item, ":", parts: 2) do
        [key, ""] when key != "" -> [{key, :unlimited}]
        [key, value] when key != "" -> parse_limit_pair(key, value)
        _ -> []
      end
    end)
  end

  defp parse_limit_pair(key, value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> [{key, limit}]
      _ -> []
    end
  end

  defp parse_integer_value(value, default) do
    case Integer.parse(string_value(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: ""
end
