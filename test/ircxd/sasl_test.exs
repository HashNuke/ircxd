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

  test "builds RFC 7677 SCRAM-SHA-256 client-first message" do
    first = SASL.scram_sha256_client_first("user", "rOprNGfwEbeRWgbNEkqO")

    assert first.bare == "n=user,r=rOprNGfwEbeRWgbNEkqO"
    assert first.message == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO"
    assert first.payload == Base.encode64(first.message)
  end

  test "escapes SCRAM usernames" do
    first = SASL.scram_sha256_client_first("user,name=one", "nonce")

    assert first.bare == "n=user=2Cname=3Done,r=nonce"
  end

  test "builds RFC 7677 SCRAM-SHA-256 client-final message and server signature" do
    server_first =
      "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," <>
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

    assert {:ok, final} =
             SASL.scram_sha256_client_final(
               "n=user,r=rOprNGfwEbeRWgbNEkqO",
               server_first,
               "pencil"
             )

    assert final.message ==
             "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," <>
               "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="

    assert final.payload == Base.encode64(final.message)
    assert final.server_signature == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
  end

  test "verifies SCRAM-SHA-256 server-final signatures" do
    assert :ok =
             SASL.verify_scram_sha256_server_final(
               "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
               "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
             )

    assert {:error, :invalid_server_signature} =
             SASL.verify_scram_sha256_server_final(
               "v=bad",
               "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
             )
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
