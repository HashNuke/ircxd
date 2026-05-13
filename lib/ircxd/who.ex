defmodule Ircxd.Who do
  @moduledoc """
  Parsers for WHO/WHOX replies.
  """

  def parse_reply([_me, channel, username, host, server, nick, flags, hops_and_realname]) do
    {hops, realname} = parse_hops_realname(hops_and_realname)

    %{
      channel: channel,
      username: username,
      host: host,
      server: server,
      nick: nick,
      flags: flags,
      away?: String.contains?(flags, "G"),
      oper?: String.contains?(flags, "*"),
      prefixes: membership_prefixes(flags),
      hops: hops,
      realname: realname
    }
  end

  def parse_reply(_params), do: nil

  def parse_whox([_me, _token | fields]) do
    parse_whox_fields(fields)
  end

  def parse_whox(_params), do: nil

  defp parse_hops_realname(value) do
    case String.split(value, " ", parts: 2) do
      [hops, realname] -> {parse_int(hops), realname}
      [realname] -> {nil, realname}
    end
  end

  defp parse_whox_fields(fields) do
    keys = [:channel, :username, :host, :server, :nick, :flags, :account, :realname]

    keys
    |> Enum.zip(fields)
    |> Map.new()
  end

  defp membership_prefixes(flags) do
    flags
    |> String.graphemes()
    |> Enum.filter(&(&1 in ["~", "&", "@", "%", "+"]))
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
