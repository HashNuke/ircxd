defmodule Ircxd.Server.Event do
  @moduledoc """
  A committed server-domain event delivered to an `Ircxd.Server.Adapter`.

  Events describe accepted state changes rather than raw socket input. In
  particular, credential-bearing commands are never represented as events.
  """

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
