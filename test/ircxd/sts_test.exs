defmodule Ircxd.STSTest do
  use ExUnit.Case, async: true

  alias Ircxd.STS

  test "parses insecure upgrade policies" do
    assert STS.parse("port=6697,duration=3600", false) ==
             {:ok,
              %{
                type: :upgrade,
                port: 6697,
                tokens: %{"port" => "6697", "duration" => "3600"}
              }}
  end

  test "parses secure persistence policies" do
    assert STS.parse("duration=3600,preload,unknown=value", true) ==
             {:ok,
              %{
                type: :persistence,
                duration: 3600,
                preload?: true,
                tokens: %{"duration" => "3600", "preload" => true, "unknown" => "value"}
              }}
  end

  test "rejects policies missing the required key for the transport" do
    assert STS.parse("duration=3600", false) == {:error, :invalid_sts_policy}
    assert STS.parse("port=6697", true) == {:error, :invalid_sts_policy}
  end

  test "rejects invalid port and duration values" do
    assert STS.parse("port=0", false) == {:error, :invalid_sts_policy}
    assert STS.parse("port=65536", false) == {:error, :invalid_sts_policy}
    assert STS.parse("port=6697x", false) == {:error, :invalid_sts_policy}
    assert STS.parse("duration=one-hour", true) == {:error, :invalid_sts_policy}
  end
end
