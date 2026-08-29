defmodule Ircxd.Source do
  @moduledoc """
  Parser for IRC message sources.

  A source may be a server name or a client mask in the common
  `nick!user@host` form.
  """

  defstruct raw: nil, type: nil, nick: nil, user: nil, host: nil, server: nil

  @typedoc "A parsed server name or user mask."
  @type t :: %__MODULE__{
          raw: String.t() | nil,
          type: :server | :user | nil,
          nick: String.t() | nil,
          user: String.t() | nil,
          host: String.t() | nil,
          server: String.t() | nil
        }

  @doc "Parses a server name or user mask. Returns `nil` for a `nil` source."
  def parse(nil), do: nil

  def parse(source) when is_binary(source) do
    case Regex.run(~r/\A([^!@]+)(?:!([^@]+))?(?:@(.+))?\z/, source) do
      [_, nick, user, host] ->
        %__MODULE__{raw: source, type: :user, nick: nick, user: blank_to_nil(user), host: host}

      [_, nick, user] ->
        %__MODULE__{raw: source, type: :user, nick: nick, user: user}

      [_, nick] ->
        if server_name?(nick) do
          %__MODULE__{raw: source, type: :server, server: source}
        else
          %__MODULE__{raw: source, type: :user, nick: nick}
        end

      nil ->
        %__MODULE__{raw: source, type: :server, server: source}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp server_name?(source), do: String.contains?(source, ".")
end
