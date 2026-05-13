defmodule Ircxd.STS do
  @moduledoc """
  Parser helpers for the IRCv3 Strict Transport Security capability.
  """

  def parse(value, tls?) when is_binary(value) do
    tokens = parse_tokens(value)

    cond do
      tls? and valid_duration?(tokens) ->
        {:ok,
         %{
           type: :persistence,
           duration: parse_int(tokens["duration"]),
           preload?: Map.has_key?(tokens, "preload"),
           tokens: tokens
         }}

      not tls? and valid_port?(tokens) ->
        {:ok,
         %{
           type: :upgrade,
           port: parse_int(tokens["port"]),
           tokens: tokens
         }}

      true ->
        {:error, :invalid_sts_policy}
    end
  end

  def parse(_value, _tls?), do: {:error, :invalid_sts_policy}

  defp parse_tokens(value) do
    value
    |> String.split(",", trim: true)
    |> Map.new(fn token ->
      case String.split(token, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, true}
      end
    end)
  end

  defp valid_duration?(%{"duration" => duration}), do: parse_int(duration) != nil
  defp valid_duration?(_tokens), do: false

  defp valid_port?(%{"port" => port}), do: parse_int(port) in 1..65_535
  defp valid_port?(_tokens), do: false

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil
end
