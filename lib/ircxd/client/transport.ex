defmodule Ircxd.Client.Transport do
  @moduledoc """
  Transport boundary for `Ircxd.Client`.

  `Ircxd.Client.Transport.Socket` is the default adapter and preserves the existing TCP/TLS
  behavior. A configured adapter owns connection establishment and serialized writes, delivers
  framed IRC records to the client with `deliver/4`, and is told when the client accepts a record.

  Returning a resumed connection restores bounded protocol state without sending IRC registration
  commands again. Transport metadata is emitted unchanged in the client's `:resumed` event. A
  custom adapter's `connect/3` configuration and retained checkpoints exclude credentials and raw
  TLS options. `send_data/2` necessarily receives complete IRC wire records, including registration
  or authentication commands, so adapters must treat outbound data as sensitive.
  """

  alias Ircxd.Client.Resume

  @typedoc "Public, credential-free connection settings passed to an adapter."
  @type config :: %{
          host: String.t(),
          port: :inet.port_number(),
          tls?: boolean(),
          sni: String.t()
        }

  @typedoc "Adapter-owned identity for one active transport connection."
  @type handle :: term()

  @typedoc "Adapter-owned receipt reported after an inbound record is accepted."
  @type receipt :: term()

  @typedoc "Whether IRC registration is required for the connected transport."
  @type mode :: :fresh | {:resumed, Resume.t(), map()}

  @doc "Connects one client using the adapter's initialization argument."
  @callback connect(client :: pid(), config(), init_arg :: term()) ::
              {:ok, handle(), mode()} | {:error, term()}

  @doc "Writes one serialized IRC record through the active transport."
  @callback send_data(handle(), iodata()) :: :ok | {:error, term()}

  @doc "Enables delivery of the next inbound record."
  @callback activate(handle()) :: :ok | {:error, term()}

  @doc "Returns whether accepted records require resumable parser checkpoints."
  @callback checkpoint?(handle()) :: boolean()

  @doc "Reports an accepted receipt and its complete post-record protocol checkpoint."
  @callback accepted(
              handle(),
              receipt(),
              Resume.t() | nil | {:unavailable, Resume.unavailable_reason()}
            ) :: :ok | {:error, term()}

  @doc "Releases one transport handle. Implementations must tolerate repeated calls."
  @callback close(handle(), reason :: term()) :: :ok | {:error, term()}

  @doc "Translates an adapter-owned process message into a transport event."
  @callback handle_info(message :: term(), handle()) ::
              :unknown | {:data, receipt(), binary()} | {:closed, term()}

  @doc "Delivers one framed IRC record to a client using the active transport handle."
  @spec deliver(pid(), handle(), receipt(), binary()) :: :ok
  def deliver(client, handle, receipt, line) when is_pid(client) and is_binary(line) do
    send(client, {:ircxd_transport, handle, {:data, receipt, line}})
    :ok
  end

  @doc "Reports closure of one transport handle to its client."
  @spec closed(pid(), handle(), term()) :: :ok
  def closed(client, handle, reason) when is_pid(client) do
    send(client, {:ircxd_transport, handle, {:closed, reason}})
    :ok
  end
end
