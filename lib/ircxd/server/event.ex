defmodule Ircxd.Server.Event do
  @moduledoc """
  A committed server-domain event delivered to an `Ircxd.Server.Adapter`.

  Events describe accepted state changes rather than raw socket input. In
  particular, credential-bearing commands are never represented as events.

  The `:type` field identifies the change. The `:data` field contains the
  event-specific data. The other fields identify the server and event time.
  """

  @typedoc "A committed server state change."
  @type t :: %__MODULE__{
          type: atom(),
          server_id: term(),
          server_name: String.t(),
          at: DateTime.t(),
          data: map()
        }

  @enforce_keys [:type, :server_id, :server_name, :at]
  defstruct [:type, :server_id, :server_name, :at, data: %{}]
end
