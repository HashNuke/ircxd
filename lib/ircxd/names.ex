defmodule Ircxd.Names do
  @moduledoc """
  Parser helpers for `RPL_NAMREPLY` (`353`) entries.
  """

  alias Ircxd.Source

  @prefixes ["~", "&", "@", "%", "+"]

  def parse_names(names) when is_binary(names) do
    names
    |> String.split(" ", trim: true)
    |> Enum.map(&parse_name/1)
  end

  def parse_name(name) do
    {prefixes, source_or_nick} = split_prefixes(name, [])

    case Source.parse(source_or_nick) do
      %Source{type: :user} = source ->
        %{
          nick: source.nick,
          prefixes: prefixes,
          user: source.user,
          host: source.host,
          raw_source: source.raw
        }

      _ ->
        %{nick: source_or_nick, prefixes: prefixes}
    end
  end

  defp split_prefixes(<<prefix::binary-size(1), rest::binary>>, acc) when prefix in @prefixes do
    split_prefixes(rest, [prefix | acc])
  end

  defp split_prefixes(nick, acc), do: {Enum.reverse(acc), nick}
end
