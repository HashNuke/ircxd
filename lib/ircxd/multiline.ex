defmodule Ircxd.Multiline do
  @moduledoc """
  Helpers for the IRCv3 draft multiline extension.
  """

  @concat_tag "draft/multiline-concat"

  def concat_tag, do: @concat_tag

  @spec combine([%{required(:body) => String.t(), optional(:concat?) => boolean()}]) :: String.t()
  def combine(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      separator =
        cond do
          acc == [] -> ""
          Map.get(line, :concat?, false) -> ""
          true -> "\n"
        end

      [acc, separator, line.body]
    end)
    |> IO.iodata_to_binary()
  end

  @spec split(String.t()) :: [%{body: String.t(), concat?: false}]
  def split(text) when is_binary(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map(&%{body: &1, concat?: false})
  end
end
