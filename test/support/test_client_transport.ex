defmodule Ircxd.TestClientTransport do
  @moduledoc false

  @behaviour Ircxd.Client.Transport

  alias Ircxd.Client.Transport

  def deliver(client, handle, receipt, line) do
    Transport.deliver(client, handle, receipt, line)
  end

  def close(client, handle, reason) do
    Transport.closed(client, handle, reason)
  end

  @impl true
  def connect(client, config, opts) do
    owner = Keyword.fetch!(opts, :owner)
    mode = Keyword.get(opts, :mode, :fresh)
    close_result = Keyword.get(opts, :close_result, :ok)
    send_result = Keyword.get(opts, :send_result, :ok)
    handle = {__MODULE__, make_ref(), owner, close_result, send_result}
    send(owner, {:test_transport_connected, client, handle, config})
    {:ok, handle, mode}
  end

  @impl true
  def send_data({_module, _ref, owner, _close_result, send_result} = handle, data) do
    send(owner, {:test_transport_sent, handle, IO.iodata_to_binary(data)})
    send_result
  end

  @impl true
  def send_data_once(
        {_module, _ref, owner, _close_result, send_result} = handle,
        keys,
        data
      ) do
    send(owner, {:test_transport_sent_once, handle, keys, IO.iodata_to_binary(data)})
    send_result
  end

  @impl true
  def activate({_module, _ref, owner, _close_result, _send_result} = handle) do
    send(owner, {:test_transport_activated, handle})
    :ok
  end

  @impl true
  def checkpoint?(_handle), do: true

  @impl true
  def accepted({_module, _ref, owner, _close_result, _send_result} = handle, receipt, checkpoint) do
    send(owner, {:test_transport_accepted, handle, receipt, checkpoint})
    :ok
  end

  @impl true
  def handle_info(_message, _handle), do: :unknown

  @impl true
  def close({_module, _ref, owner, close_result, _send_result} = handle, reason) do
    send(owner, {:test_transport_released, handle, reason})
    close_result
  end
end
