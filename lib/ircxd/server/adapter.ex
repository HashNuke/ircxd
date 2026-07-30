defmodule Ircxd.Server.Adapter do
  @moduledoc """
  Application-owned server adapter contract.

  The adapter state is shared by message publication and authentication, so an
  application can keep authentication policy and attempt tracking in one place.
  """

  alias Ircxd.Message

  @callback init(term()) :: {:ok, term()}

  @callback handle_publish(Message.t(), map(), term()) :: {:ok, term()}

  @callback authenticate(String.t(), String.t(), map(), term()) ::
              {:ok, term(), term()} | {:error, term(), term()}

  @optional_callbacks authenticate: 4, handle_publish: 3
end
