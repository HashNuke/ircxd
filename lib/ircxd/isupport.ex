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
end
