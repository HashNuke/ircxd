defmodule Ircxd.UserHost do
  @moduledoc """
  Parser helpers for `RPL_USERHOST` (`302`) replies.
  """

  @reply_pattern ~r/\A(?<nick>[^*=]+)(?<oper>\*)?=(?<away>[+-])(?<username>[^@]+)@(?<host>.+)\z/

  def parse_replies(replies) when is_binary(replies) do
    replies
    |> String.split(" ", trim: true)
    |> Enum.map(&parse_reply/1)
  end

  def parse_replies(_replies), do: []

  def parse_reply(reply) when is_binary(reply) do
    case Regex.named_captures(@reply_pattern, reply) do
      %{"nick" => nick, "oper" => oper, "away" => away, "username" => username, "host" => host} ->
        %{
          raw: reply,
          nick: nick,
          oper?: oper == "*",
          away?: away == "-",
          username: username,
          host: host
        }

      nil ->
        %{raw: reply}
    end
  end

  def parse_reply(reply), do: %{raw: reply}
end
