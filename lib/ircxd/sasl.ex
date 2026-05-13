defmodule Ircxd.SASL do
  @moduledoc """
  SASL helpers for IRC authentication.

  IRC networks commonly use SASL PLAIN during registration after the `sasl`
  capability is acknowledged. The payload is base64 encoded as:

      authzid NUL authcid NUL password
  """

  @max_authenticate_payload_bytes 400
  @gs2_header "n,,"

  def plain_payload(username, password, authzid \\ "") do
    [authzid, <<0>>, username, <<0>>, password]
    |> IO.iodata_to_binary()
    |> Base.encode64()
  end

  def external_payload(nil), do: "+"
  def external_payload(""), do: "+"
  def external_payload(authzid) when is_binary(authzid), do: Base.encode64(authzid)

  def scram_sha256_client_first(username, nonce) when is_binary(username) and is_binary(nonce) do
    bare = "n=#{scram_escape(username)},r=#{nonce}"
    message = @gs2_header <> bare

    %{bare: bare, message: message, payload: Base.encode64(message)}
  end

  def scram_sha256_client_final(client_first_bare, server_first, password)
      when is_binary(client_first_bare) and is_binary(server_first) and is_binary(password) do
    with {:ok, attrs} <- parse_scram_attributes(server_first),
         {:ok, nonce} <- fetch_scram_attr(attrs, "r"),
         {:ok, salt} <- fetch_scram_attr(attrs, "s"),
         {:ok, decoded_salt} <- Base.decode64(salt),
         {:ok, iterations} <- fetch_scram_iterations(attrs) do
      client_final_without_proof = "c=#{Base.encode64(@gs2_header)},r=#{nonce}"
      auth_message = Enum.join([client_first_bare, server_first, client_final_without_proof], ",")

      salted_password = :crypto.pbkdf2_hmac(:sha256, password, decoded_salt, iterations, 32)

      client_key = hmac(salted_password, "Client Key")
      stored_key = :crypto.hash(:sha256, client_key)
      client_signature = hmac(stored_key, auth_message)
      client_proof = xor_binary(client_key, client_signature)
      server_key = hmac(salted_password, "Server Key")
      server_signature = hmac(server_key, auth_message) |> Base.encode64()
      message = client_final_without_proof <> ",p=#{Base.encode64(client_proof)}"

      {:ok,
       %{message: message, payload: Base.encode64(message), server_signature: server_signature}}
    end
  end

  def verify_scram_sha256_server_final(server_final, expected_signature)
      when is_binary(server_final) and is_binary(expected_signature) do
    with {:ok, attrs} <- parse_scram_attributes(server_final),
         {:ok, signature} <- fetch_scram_attr(attrs, "v") do
      if secure_compare(signature, expected_signature) do
        :ok
      else
        {:error, :invalid_server_signature}
      end
    end
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

  defp parse_scram_attributes(message) do
    attrs =
      message
      |> String.split(",", trim: true)
      |> Enum.reduce_while({:ok, %{}}, fn attr, {:ok, acc} ->
        case String.split(attr, "=", parts: 2) do
          [key, value] when key != "" -> {:cont, {:ok, Map.put(acc, key, value)}}
          _ -> {:halt, {:error, :invalid_scram_attribute}}
        end
      end)

    attrs
  end

  defp fetch_scram_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when value != "" -> {:ok, value}
      _ -> {:error, {:missing_scram_attribute, key}}
    end
  end

  defp fetch_scram_iterations(attrs) do
    with {:ok, value} <- fetch_scram_attr(attrs, "i"),
         {iterations, ""} when iterations > 0 <- Integer.parse(value) do
      {:ok, iterations}
    else
      _ -> {:error, :invalid_scram_iterations}
    end
  end

  defp scram_escape(value) do
    value
    |> String.replace("=", "=3D")
    |> String.replace(",", "=2C")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp xor_binary(left, right), do: xor_binary(left, right, <<>>)
  defp xor_binary(<<>>, <<>>, acc), do: acc

  defp xor_binary(<<left, left_rest::binary>>, <<right, right_rest::binary>>, acc) do
    xor_binary(left_rest, right_rest, <<acc::binary, Bitwise.bxor(left, right)>>)
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, acc ->
      Bitwise.bor(acc, Bitwise.bxor(left_byte, right_byte))
    end) == 0
  end

  defp secure_compare(_left, _right), do: false

  defp chunk_binary("", _size), do: []

  defp chunk_binary(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_binary(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunk_binary(rest, size)]
  end
end
