defmodule Ircxd.Casemapping do
  @moduledoc """
  IRC casemapping helpers.

  Modern IRC servers advertise their casemapping in `RPL_ISUPPORT` with the
  `CASEMAPPING` token. Clients need this when comparing nicknames and channel
  names.
  """

  @type mapping :: :ascii | :rfc1459 | :strict_rfc1459

  def normalize(value, mapping \\ :rfc1459)

  def normalize(value, :ascii) when is_binary(value), do: ascii_downcase(value)

  def normalize(value, :rfc1459) when is_binary(value) do
    value
    |> ascii_downcase()
    |> String.replace("[", "{")
    |> String.replace("]", "}")
    |> String.replace("\\", "|")
    |> String.replace("~", "^")
  end

  def normalize(value, :strict_rfc1459) when is_binary(value) do
    value
    |> ascii_downcase()
    |> String.replace("[", "{")
    |> String.replace("]", "}")
    |> String.replace("\\", "|")
  end

  def equal?(left, right, mapping \\ :rfc1459) do
    normalize(left, mapping) == normalize(right, mapping)
  end

  def from_isupport(nil), do: :rfc1459
  def from_isupport("ascii"), do: :ascii
  def from_isupport("rfc1459"), do: :rfc1459
  def from_isupport("strict-rfc1459"), do: :strict_rfc1459
  def from_isupport(_), do: :rfc1459

  defp ascii_downcase(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map(fn
      byte when byte in ?A..?Z -> byte + 32
      byte -> byte
    end)
    |> :binary.list_to_bin()
  end
end
