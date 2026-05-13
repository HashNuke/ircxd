defmodule Ircxd.ClientTagDeny do
  @moduledoc """
  Helpers for the IRCv3 `CLIENTTAGDENY` ISUPPORT token.
  """

  def denied?(nil, _tag), do: false
  def denied?("", _tag), do: false

  def denied?(value, tag) when is_binary(value) do
    tag = normalize_tag(tag)
    entries = String.split(value, ",", trim: true)

    cond do
      "*" in entries -> tag not in exemptions(entries)
      true -> tag in entries
    end
  end

  def denied?(_value, _tag), do: false

  defp normalize_tag("+" <> tag), do: tag
  defp normalize_tag(tag), do: tag

  defp exemptions(entries) do
    entries
    |> Enum.filter(&String.starts_with?(&1, "-"))
    |> Enum.map(&String.trim_leading(&1, "-"))
  end
end
