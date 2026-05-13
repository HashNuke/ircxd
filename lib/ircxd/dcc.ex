defmodule Ircxd.DCC do
  @moduledoc """
  Helpers for CTCP DCC query payloads.

  This module only parses and serializes DCC negotiation messages. Direct TCP
  connections, file writes, and user-consent policy belong in the host
  application.
  """

  alias Ircxd.CTCP

  defstruct type: nil,
            argument: nil,
            host: nil,
            raw_host: nil,
            port: nil,
            position: nil,
            reverse?: false,
            extra: []

  @type t :: %__MODULE__{
          type: String.t(),
          argument: String.t(),
          host: String.t(),
          raw_host: String.t(),
          port: non_neg_integer(),
          position: non_neg_integer() | nil,
          reverse?: boolean(),
          extra: [String.t()]
        }

  @spec parse(CTCP.t() | String.t()) :: {:ok, t()} | {:error, atom()}
  def parse(%CTCP{command: "DCC", params: params}), do: parse(params)
  def parse(%CTCP{}), do: {:error, :not_dcc}

  def parse("DCC " <> params), do: parse(params)

  def parse(params) when is_binary(params) do
    with {:ok, [type, argument, raw_host, raw_port | extra]} <- tokenize(params),
         {:ok, port} <- parse_port(raw_port),
         {:ok, host} <- normalize_host(raw_host),
         {:ok, position} <- parse_position(type, extra) do
      {:ok,
       %__MODULE__{
         type: String.upcase(type),
         argument: argument,
         host: host,
         raw_host: raw_host,
         port: port,
         position: position,
         reverse?: port == 0,
         extra: extra
       }}
    else
      {:ok, _too_few} -> {:error, :not_enough_params}
      error -> error
    end
  end

  @spec encode_chat(String.t(), non_neg_integer(), String.t()) :: String.t()
  def encode_chat(host, port, argument \\ "chat") do
    encode("CHAT", argument, host, port)
  end

  @spec encode_send(String.t(), String.t(), non_neg_integer(), [String.t() | integer()]) ::
          String.t()
  def encode_send(filename, host, port, extra \\ []) do
    encode("SEND", filename, host, port, extra)
  end

  @spec encode_resume(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def encode_resume(filename, host, port, position) do
    encode("RESUME", filename, host, port, [position])
  end

  @spec encode_accept(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def encode_accept(filename, host, port, position) do
    encode("ACCEPT", filename, host, port, [position])
  end

  @spec encode(String.t(), String.t(), String.t() | tuple(), non_neg_integer(), [
          String.t() | integer()
        ]) :: String.t()
  def encode(type, argument, host, port, extra \\ []) do
    payload =
      [
        "DCC",
        String.upcase(type),
        quote_arg(argument),
        encode_host(host),
        Integer.to_string(port) | extra
      ]
      |> Enum.map(&to_string/1)
      |> Enum.join(" ")

    CTCP.encode("DCC", String.replace_prefix(payload, "DCC ", ""))
  end

  defp tokenize(params), do: do_tokenize(String.trim(params), [])

  defp do_tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(<<34, rest::binary>>, acc) do
    case take_quoted(rest, []) do
      {:ok, token, rest} -> do_tokenize(String.trim_leading(rest), [token | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_tokenize(rest, acc) do
    case String.split(rest, " ", parts: 2, trim: true) do
      [token, rest] -> do_tokenize(String.trim_leading(rest), [token | acc])
      [token] -> {:ok, Enum.reverse([token | acc])}
      [] -> {:ok, Enum.reverse(acc)}
    end
  end

  defp take_quoted(<<>>, _acc), do: {:error, :unterminated_quote}

  defp take_quoted(<<34, rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_quoted(<<92, 34, rest::binary>>, acc), do: take_quoted(rest, [<<34>> | acc])
  defp take_quoted(<<92, 92, rest::binary>>, acc), do: take_quoted(rest, [<<92>> | acc])

  defp take_quoted(<<char::utf8, rest::binary>>, acc),
    do: take_quoted(rest, [<<char::utf8>> | acc])

  defp parse_port(raw_port) do
    case Integer.parse(raw_port) do
      {port, ""} when port in 0..65_535 -> {:ok, port}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_position(type, [raw_position | _extra])
       when type in ["RESUME", "resume", "ACCEPT", "accept"] do
    case Integer.parse(raw_position) do
      {position, ""} when position >= 0 -> {:ok, position}
      _ -> {:error, :invalid_position}
    end
  end

  defp parse_position(type, []) when type in ["RESUME", "resume", "ACCEPT", "accept"],
    do: {:error, :missing_position}

  defp parse_position(_type, _extra), do: {:ok, nil}

  defp normalize_host(raw_host) do
    cond do
      String.contains?(raw_host, ":") ->
        {:ok, raw_host}

      true ->
        case Integer.parse(raw_host) do
          {int, ""} when int in 0..4_294_967_295 -> {:ok, decode_ipv4_integer(int)}
          _ -> {:ok, raw_host}
        end
    end
  end

  defp decode_ipv4_integer(int) do
    [
      Bitwise.band(Bitwise.bsr(int, 24), 255),
      Bitwise.band(Bitwise.bsr(int, 16), 255),
      Bitwise.band(Bitwise.bsr(int, 8), 255),
      Bitwise.band(int, 255)
    ]
    |> Enum.join(".")
  end

  defp encode_host({a, b, c, d})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    [a, b, c, d]
    |> Enum.reduce(0, fn octet, acc -> acc * 256 + octet end)
    |> Integer.to_string()
  end

  defp encode_host(host), do: to_string(host)

  defp quote_arg(argument) do
    argument = to_string(argument)

    if String.contains?(argument, " ") do
      escaped =
        argument
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")

      "\"" <> escaped <> "\""
    else
      argument
    end
  end
end
