defmodule Ircxd.Metadata do
  @moduledoc """
  Parser helpers for the IRCv3 draft metadata extension.
  """

  @spec valid_key?(String.t()) :: boolean()
  def valid_key?(key) when is_binary(key) do
    String.match?(key, ~r/\A[a-z0-9_.\/-]+\z/)
  end

  @spec parse_message([String.t()]) :: {:ok, map()} | {:error, atom()}
  def parse_message([target, key, visibility, value]) do
    {:ok, %{target: target, key: key, visibility: visibility, value: value}}
  end

  def parse_message(_params), do: {:error, :invalid_metadata_message}

  @spec parse_numeric(String.t(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def parse_numeric(command, [_me | params]), do: parse_reply(command, params)
  def parse_numeric(_command, _params), do: {:error, :invalid_metadata_numeric}

  defp parse_reply(command, [target, key, visibility, value]) when command in ["760", "761"] do
    {:ok,
     %{
       type: key_value_type(command),
       target: target,
       key: key,
       visibility: visibility,
       value: value
     }}
  end

  defp parse_reply("766", [target, key | _description]) do
    {:ok, %{type: :key_not_set, target: target, key: key}}
  end

  defp parse_reply("770", keys), do: {:ok, %{type: :sub_ok, keys: keys}}
  defp parse_reply("771", keys), do: {:ok, %{type: :unsub_ok, keys: keys}}
  defp parse_reply("772", keys), do: {:ok, %{type: :subs, keys: keys}}

  defp parse_reply("774", [target]) do
    {:ok, %{type: :sync_later, target: target, retry_after: nil}}
  end

  defp parse_reply("774", [target, retry_after]) do
    {:ok, %{type: :sync_later, target: target, retry_after: parse_int(retry_after)}}
  end

  defp parse_reply(_command, _params), do: {:error, :unsupported_metadata_numeric}

  defp key_value_type("760"), do: :whois_key_value
  defp key_value_type("761"), do: :key_value

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
