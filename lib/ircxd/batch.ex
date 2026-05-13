defmodule Ircxd.Batch do
  @moduledoc """
  Parser helpers for IRCv3 BATCH messages.
  """

  @spec parse([String.t()]) ::
          {:ok, %{direction: :start, ref: String.t(), type: String.t(), params: [String.t()]}}
          | {:ok, %{direction: :end, ref: String.t()}}
          | {:error, atom()}
  def parse([]), do: {:error, :missing_reference}

  def parse(["+" <> _ref]), do: {:error, :missing_type}

  def parse(["+" <> ref, type | params]) when ref != "" and type != "" do
    {:ok, %{direction: :start, ref: ref, type: type, params: params}}
  end

  def parse(["-" <> ref]) when ref != "" do
    {:ok, %{direction: :end, ref: ref}}
  end

  def parse(["+" | _params]), do: {:error, :missing_reference}
  def parse(["-" | _params]), do: {:error, :missing_reference}
  def parse(_params), do: {:error, :invalid_reference}
end
