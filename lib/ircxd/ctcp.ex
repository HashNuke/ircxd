defmodule Ircxd.CTCP do
  @moduledoc """
  Helpers for Client-To-Client Protocol payloads.

  CTCP is transported inside `PRIVMSG` or `NOTICE` bodies using `0x01`
  delimiters.
  """

  @delimiter <<1>>

  defstruct command: nil, params: nil

  @type t :: %__MODULE__{command: String.t(), params: String.t()}

  def encode(command, params \\ "") do
    params = to_string(params)

    payload =
      if params == "" do
        String.upcase(command)
      else
        String.upcase(command) <> " " <> params
      end

    @delimiter <> payload <> @delimiter
  end

  def decode(@delimiter <> rest) do
    case String.split(rest, @delimiter, parts: 2) do
      [payload, _] -> decode_payload(payload)
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp decode_payload(payload) do
    case String.split(payload, " ", parts: 2) do
      [command, params] -> {:ok, %__MODULE__{command: String.upcase(command), params: params}}
      [command] -> {:ok, %__MODULE__{command: String.upcase(command), params: ""}}
    end
  end
end
