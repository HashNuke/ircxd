defmodule Ircxd.WebSocket.MemoryAdapter do
  @moduledoc """
  In-memory `Ircxd.WebSocket.Adapter` implementation.

  This adapter is useful for tests and embedders that want to verify payloads at
  the adapter boundary without depending on a specific WebSocket server stack.
  It sends frames to the owner process as `{:ircxd_websocket_frame, mode,
  payload}`.
  """

  @behaviour Ircxd.WebSocket.Adapter

  @impl true
  def send_frame(owner, mode, payload) when is_pid(owner) do
    send(owner, {:ircxd_websocket_frame, mode, payload})
    :ok
  end

  def send_frame({owner, tag}, mode, payload) when is_pid(owner) do
    send(owner, {tag, mode, payload})
    :ok
  end

  def send_frame(_owner, _mode, _payload), do: {:error, :invalid_owner}

  @impl true
  def close(owner, reason) when is_pid(owner) do
    send(owner, {:ircxd_websocket_closed, reason})
    :ok
  end

  def close({owner, tag}, reason) when is_pid(owner) do
    send(owner, {tag, :closed, reason})
    :ok
  end

  def close(_owner, _reason), do: {:error, :invalid_owner}
end
