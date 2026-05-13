defmodule Ircxd.SASL do
  @moduledoc """
  SASL helpers for IRC authentication.

  IRC networks commonly use SASL PLAIN during registration after the `sasl`
  capability is acknowledged. The payload is base64 encoded as:

      authzid NUL authcid NUL password
  """

  @max_authenticate_payload_bytes 400

  def plain_payload(username, password, authzid \\ "") do
    [authzid, <<0>>, username, <<0>>, password]
    |> IO.iodata_to_binary()
    |> Base.encode64()
  end

  def authenticate_chunks(payload) when is_binary(payload) do
    chunks =
      payload
      |> chunk_binary(@max_authenticate_payload_bytes)
      |> then(fn
        [] -> ["+"]
        chunks -> chunks
      end)

    if rem(byte_size(payload), @max_authenticate_payload_bytes) == 0 do
      chunks ++ ["+"]
    else
      chunks
    end
  end

  def max_authenticate_payload_bytes, do: @max_authenticate_payload_bytes

  defp chunk_binary("", _size), do: []

  defp chunk_binary(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_binary(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunk_binary(rest, size)]
  end
end
