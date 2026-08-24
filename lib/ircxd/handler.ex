defmodule Ircxd.Handler do
  @moduledoc """
  Compatibility callback behaviour for applications embedding `Ircxd.Client`.

  New integrations should implement `Ircxd.Client.Adapter` and configure the
  client with `adapter: {Module, init_arg}`. The legacy `:handler` option and
  two-argument event callback remain supported.
  """

  @callback init(term()) :: {:ok, term()}
  @callback handle_event(term(), term()) :: {:ok, term()}
end
