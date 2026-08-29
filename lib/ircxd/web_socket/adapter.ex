defmodule Ircxd.WebSocket.Adapter do
  @moduledoc """
  Behaviour for host-application WebSocket adapters.

  `ircxd` keeps WebSocket support at the IRC protocol boundary: it validates
  IRCv3 WebSocket payloads and asks an adapter owned by the host application to
  deliver those payloads over Phoenix Channels, Cowboy, Bandit, or another
  WebSocket stack.
  """

  @typedoc "The WebSocket frame type."
  @type mode :: :binary | :text

  @typedoc "Host-application WebSocket state."
  @type state :: term()

  @doc "Sends one validated IRC payload in a WebSocket frame."
  @callback send_frame(state(), mode(), binary()) :: :ok | {:error, term()}

  @doc "Closes the host WebSocket connection."
  @callback close(state(), term()) :: :ok | {:error, term()}

  @optional_callbacks close: 2
end
