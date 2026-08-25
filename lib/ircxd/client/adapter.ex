defmodule Ircxd.Client.Adapter do
  @moduledoc """
  Application integration contract for an `Ircxd.Client` process.

  A client adapter receives normalized client events and owns any application
  state derived from them. It is configured with the client's `:adapter`
  option as `{module, init_arg}`.
  """

  @type state :: term()
  @type event :: Ircxd.Client.Event.legacy() | Ircxd.Client.Event.t()
  @type context :: %{
          client: pid(),
          host: String.t(),
          port: :inet.port_number(),
          tls?: boolean(),
          nick: String.t() | nil,
          client_info: Ircxd.Client.Info.t()
        }

  @callback init(term()) :: {:ok, state()} | {:error, term()}
  @callback handle_event(event(), context(), state()) :: {:ok, state()}
end
