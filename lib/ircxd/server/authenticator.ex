defmodule Ircxd.Server.Authenticator do
  @moduledoc """
  Contract for application-owned IRC authentication.

  Implementations may query a database or another identity provider. The
  server only manages the SASL exchange and registration state.

  Authentication metadata includes `:mechanism`, `:transport`, `:tls?`,
  `:peer`, and, for certificate-bound SASL EXTERNAL,
  `:peer_certificate` plus its lowercase SHA-256 fingerprint in
  `:peer_certificate_sha256`.
  """

  @callback init(term()) :: {:ok, term()}

  @callback authenticate(
              username :: String.t(),
              password :: String.t(),
              metadata :: map(),
              state :: term()
            ) :: {:ok, term(), term()} | {:error, term(), term()}
end
