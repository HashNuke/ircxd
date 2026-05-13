defmodule Ircxd.FileHost do
  @moduledoc """
  Helpers for the work-in-progress `soju.im/FILEHOST` ISUPPORT token.
  """

  @token "soju.im/FILEHOST"
  @supported_schemes ["http", "https"]

  def token, do: @token

  def upload_url(isupport, tls?) when is_map(isupport) do
    case Map.fetch(isupport, @token) do
      {:ok, url} when is_binary(url) -> validate_upload_url(url, tls?)
      {:ok, _invalid} -> {:error, :invalid_filehost_uri}
      :error -> {:error, :filehost_not_advertised}
    end
  end

  defp validate_upload_url(url, tls?) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in @supported_schemes or is_nil(uri.host) ->
        {:error, :unsupported_filehost_uri}

      tls? and uri.scheme == "http" ->
        {:error, :insecure_filehost_transport}

      true ->
        {:ok, url}
    end
  end
end
