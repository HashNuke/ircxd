defmodule Ircxd.Whois do
  @moduledoc """
  Parser helpers for WHOIS numerics.
  """

  def parse_user([_me, nick, username, host, _star, realname]) do
    %{nick: nick, username: username, host: host, realname: realname}
  end

  def parse_user(_params), do: nil

  def parse_whowas_user([_me, nick, username, host, _star, realname]) do
    %{nick: nick, username: username, host: host, realname: realname}
  end

  def parse_whowas_user(_params), do: nil

  def parse_server([_me, nick, server, info]), do: %{nick: nick, server: server, info: info}
  def parse_server(_params), do: nil

  def parse_operator([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_operator(_params), do: nil

  def parse_certfp([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_certfp(_params), do: nil

  def parse_registered_nick([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_registered_nick(_params), do: nil

  def parse_bot([_me, nick, message]), do: %{nick: nick, message: message, bot?: true}
  def parse_bot(_params), do: nil

  def parse_idle([_me, nick, idle_seconds, signon | _rest]) do
    %{nick: nick, idle_seconds: parse_int(idle_seconds), signon: parse_int(signon)}
  end

  def parse_idle(_params), do: nil

  def parse_channels([_me, nick, channels]),
    do: %{nick: nick, channels: String.split(channels, " ", trim: true)}

  def parse_channels(_params), do: nil

  def parse_account([_me, nick, account | _rest]), do: %{nick: nick, account: account}
  def parse_account(_params), do: nil

  def parse_special([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_special(_params), do: nil

  def parse_actual_host([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_actual_host(_params), do: nil

  def parse_host([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_host(_params), do: nil

  def parse_modes([_me, nick, modes]),
    do: %{nick: nick, modes: String.split(modes, " ", trim: true)}

  def parse_modes(_params), do: nil

  def parse_secure([_me, nick, text]), do: %{nick: nick, text: text}
  def parse_secure(_params), do: nil

  def parse_end([_me, nick | _rest]), do: %{nick: nick}
  def parse_end(_params), do: nil

  def parse_whowas_end([_me, nick | _rest]), do: %{nick: nick}
  def parse_whowas_end(_params), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
