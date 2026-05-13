defmodule Ircxd.ChatHistory do
  @moduledoc """
  Helpers for the IRCv3 draft chathistory extension.
  """

  @spec ref(:latest | {:timestamp, String.t()} | {:msgid, String.t()}) :: String.t()
  def ref(:latest), do: "*"
  def ref({:timestamp, timestamp}), do: "timestamp=#{timestamp}"
  def ref({:msgid, msgid}), do: "msgid=#{msgid}"

  @spec params(tuple()) :: [String.t()]
  def params({:latest, target, selector, limit}) do
    ["LATEST", target, ref(selector), to_string(limit)]
  end

  def params({:before, target, selector, limit}) do
    ["BEFORE", target, ref(selector), to_string(limit)]
  end

  def params({:after, target, selector, limit}) do
    ["AFTER", target, ref(selector), to_string(limit)]
  end

  def params({:around, target, selector, limit}) do
    ["AROUND", target, ref(selector), to_string(limit)]
  end

  def params({:between, target, first_selector, second_selector, limit}) do
    ["BETWEEN", target, ref(first_selector), ref(second_selector), to_string(limit)]
  end

  def params({:targets, first_timestamp, second_timestamp, limit}) do
    ["TARGETS", ref(first_timestamp), ref(second_timestamp), to_string(limit)]
  end

  @spec parse_targets([String.t()]) :: {:ok, map()} | {:error, atom()}
  def parse_targets([target, latest_timestamp]) do
    {:ok, %{target: target, latest_timestamp: latest_timestamp}}
  end

  def parse_targets(_params), do: {:error, :invalid_chathistory_targets}
end
