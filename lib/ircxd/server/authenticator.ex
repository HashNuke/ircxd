defmodule Ircxd.Server.Authenticator do
  @moduledoc """
  Contract for application-owned IRC authentication.

  Implementations may query a database or another identity provider. The
  server only manages the SASL exchange and registration state.
  """

  @callback init(term()) :: {:ok, term()}

  @callback authenticate(
              username :: String.t(),
              password :: String.t(),
              metadata :: map(),
              state :: term()
            ) :: {:ok, term(), term()} | {:error, term(), term()}
end
