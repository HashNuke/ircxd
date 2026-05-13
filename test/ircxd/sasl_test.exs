defmodule Ircxd.SASLTest do
  use ExUnit.Case, async: true

  alias Ircxd.SASL

  test "builds SASL PLAIN payload" do
    assert SASL.plain_payload("user", "secret") == Base.encode64(<<0, "user", 0, "secret">>)

    assert SASL.plain_payload("authc", "secret", "authz") ==
             Base.encode64(<<"authz", 0, "authc", 0, "secret">>)
  end

  test "builds SASL EXTERNAL payload" do
    assert SASL.external_payload("nick") == Base.encode64("nick")
    assert SASL.external_payload(nil) == "+"
  end

  test "splits authenticate payloads into IRC-sized chunks" do
    payload = String.duplicate("a", 401)

    assert [first, second] = SASL.authenticate_chunks(payload)
    assert byte_size(first) == SASL.max_authenticate_payload_bytes()
    assert second == "a"
  end

  test "adds final plus chunk when payload is exactly divisible by max chunk size" do
    payload = String.duplicate("a", SASL.max_authenticate_payload_bytes())

    assert [^payload, "+"] = SASL.authenticate_chunks(payload)
  end
end
