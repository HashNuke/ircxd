defmodule Ircxd.WebSocket.Adapter do
  @moduledoc """
  Behaviour for host-application WebSocket adapters.

  `ircxd` keeps WebSocket support at the IRC protocol boundary: it validates
  IRCv3 WebSocket payloads and asks an adapter owned by the host application to
  deliver those payloads over Phoenix Channels, Cowboy, Bandit, or another
  WebSocket stack.
  """

  @type mode :: :binary | :text
  @type state :: term()

  @callback send_frame(state(), mode(), binary()) :: :ok | {:error, term()}
  @callback close(state(), term()) :: :ok | {:error, term()}

  @optional_callbacks close: 2
end
