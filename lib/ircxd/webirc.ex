defmodule Ircxd.WebIRC do
  @moduledoc """
  Helpers for the IRCv3 WebIRC command.
  """

  alias Ircxd.Message

  @spec params(keyword()) :: [String.t()]
  def params(opts) do
    params = [
      Keyword.fetch!(opts, :password),
      Keyword.fetch!(opts, :gateway),
      Keyword.fetch!(opts, :hostname),
      Keyword.fetch!(opts, :ip)
    ]

    case Keyword.get(opts, :options, []) |> options() do
      "" -> params
      options -> params ++ [options]
    end
  end

  @spec options(map() | keyword() | [{String.t(), term()}]) :: String.t()
  def options(options) when is_map(options) do
    options
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> options()
  end

  def options(options) when is_list(options) do
    options
    |> Enum.map(&option/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp option({name, true}), do: to_string(name)
  defp option({name, nil}), do: to_string(name)
  defp option({name, value}), do: "#{name}=#{Message.escape_tag_value(to_string(value))}"
end
