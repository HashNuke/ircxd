defmodule Ircxd.Client.Adapter do
  @moduledoc """
  Application integration contract for an `Ircxd.Client` process.

  A client adapter receives normalized client events and owns any application
  state derived from them. It is configured with the client's `:adapter`
  option as `{module, init_arg}`.
  """

  @typedoc "Application state for one client process."
  @type state :: term()

  @typedoc "A legacy event or an event envelope."
  @type event :: Ircxd.Client.Event.legacy() | Ircxd.Client.Event.t()

  @typedoc "Connection data for one event."
  @type context :: %{
          client: pid(),
          host: String.t(),
          port: :inet.port_number(),
          tls?: boolean(),
          nick: String.t() | nil,
          client_info: Ircxd.Client.Info.t()
        }

  @doc "Initializes the adapter state from the configured argument."
  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @doc "Handles one client event and returns the next adapter state."
  @callback handle_event(event(), context(), state()) :: {:ok, state()}
end
