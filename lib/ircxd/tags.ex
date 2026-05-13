defmodule Ircxd.Tags do
  @moduledoc """
  Convenience helpers for common IRCv3 message tags.
  """

  def server_time(%{tags: tags}), do: server_time(tags)

  def server_time(tags) when is_map(tags) do
    with time when is_binary(time) <- tags["time"],
         {:ok, datetime, _offset} <- DateTime.from_iso8601(time) do
      {:ok, datetime}
    else
      nil -> :error
      {:error, reason} -> {:error, reason}
    end
  end

  def msgid(%{tags: tags}), do: msgid(tags)
  def msgid(tags) when is_map(tags), do: Map.get(tags, "msgid")

  def label(%{tags: tags}), do: label(tags)
  def label(tags) when is_map(tags), do: Map.get(tags, "label")

  def batch(%{tags: tags}), do: batch(tags)
  def batch(tags) when is_map(tags), do: Map.get(tags, "batch")

  def account(%{tags: tags}), do: account(tags)
  def account(%{"account" => "*"}), do: nil
  def account(tags) when is_map(tags), do: Map.get(tags, "account")

  def bot?(%{tags: tags}), do: bot?(tags)
  def bot?(tags) when is_map(tags), do: Map.has_key?(tags, "bot")

  def reply_to_msgid(%{tags: tags}), do: reply_to_msgid(tags)
  def reply_to_msgid(tags) when is_map(tags), do: Map.get(tags, "+reply")

  def channel_context(%{tags: tags}), do: channel_context(tags)
  def channel_context(tags) when is_map(tags), do: Map.get(tags, "+draft/channel-context")
end
