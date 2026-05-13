defmodule Ircxd.FileHostTest do
  use ExUnit.Case, async: true

  alias Ircxd.FileHost

  test "returns advertised HTTPS upload URL" do
    assert {:ok, "https://irc.example.org/upload"} =
             FileHost.upload_url(%{"soju.im/FILEHOST" => "https://irc.example.org/upload"}, true)
  end

  test "reports missing filehost token" do
    assert {:error, :filehost_not_advertised} = FileHost.upload_url(%{}, false)
  end

  test "rejects unsupported upload URI schemes" do
    assert {:error, :unsupported_filehost_uri} =
             FileHost.upload_url(%{"soju.im/FILEHOST" => "ftp://irc.example.org/upload"}, false)
  end

  test "rejects plain HTTP filehost when IRC is encrypted" do
    assert {:error, :insecure_filehost_transport} =
             FileHost.upload_url(%{"soju.im/FILEHOST" => "http://irc.example.org/upload"}, true)
  end

  test "allows plain HTTP filehost when IRC is also plaintext" do
    assert {:ok, "http://irc.example.org/upload"} =
             FileHost.upload_url(%{"soju.im/FILEHOST" => "http://irc.example.org/upload"}, false)
  end
end
