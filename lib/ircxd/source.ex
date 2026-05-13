defmodule Ircxd.Source do
  @moduledoc """
  Parser for IRC message sources.

  A source may be a server name or a client mask in the common
  `nick!user@host` form.
  """

  defstruct raw: nil, type: nil, nick: nil, user: nil, host: nil, server: nil

  def parse(nil), do: nil

  def parse(source) when is_binary(source) do
    case Regex.run(~r/\A([^!@]+)!([^@]+)@(.+)\z/, source) do
      [_, nick, user, host] ->
        %__MODULE__{raw: source, type: :user, nick: nick, user: user, host: host}

      _ ->
        %__MODULE__{raw: source, type: :server, server: source}
    end
  end
end
