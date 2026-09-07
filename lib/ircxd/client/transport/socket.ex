defmodule Ircxd.Client.Transport.Socket do
  @moduledoc """
  Built-in TCP/TLS transport adapter used by `Ircxd.Client` by default.

  The client process remains the socket owner. This adapter contains connection setup, framed
  socket reads, active-once flow control, and serialized writes for both `:gen_tcp` and `:ssl`.
  """

  @behaviour Ircxd.Client.Transport

  alias Ircxd.Message

  @enforce_keys [:transport, :socket]
  defstruct @enforce_keys

  @type t :: %__MODULE__{transport: :gen_tcp | :ssl, socket: term()}

  @impl true
  def connect(_client, %{tls?: true} = config, init_arg) do
    tls_options = Keyword.get(init_arg, :tls_options, [])

    with {:ok, socket} <-
           :ssl.connect(
             String.to_charlist(config.host),
             config.port,
             tcp_options() ++ tls_connect_options(Map.put(config, :tls_options, tls_options)),
             10_000
           ) do
      {:ok, %__MODULE__{transport: :ssl, socket: socket}, :fresh}
    end
  end

  def connect(_client, config, _init_arg) do
    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(config.host), config.port, tcp_options(), 10_000) do
      {:ok, %__MODULE__{transport: :gen_tcp, socket: socket}, :fresh}
    end
  end

  @impl true
  def send_data(%__MODULE__{transport: :gen_tcp, socket: socket}, data),
    do: :gen_tcp.send(socket, data)

  def send_data(%__MODULE__{transport: :ssl, socket: socket}, data),
    do: :ssl.send(socket, data)

  @impl true
  def activate(%__MODULE__{transport: :gen_tcp, socket: socket}),
    do: :inet.setopts(socket, active: :once)

  def activate(%__MODULE__{transport: :ssl, socket: socket}),
    do: :ssl.setopts(socket, active: :once)

  @impl true
  def accepted(%__MODULE__{}, _receipt, _checkpoint), do: :ok

  @impl true
  def checkpoint?(%__MODULE__{}), do: false

  @impl true
  def close(%__MODULE__{transport: :gen_tcp, socket: socket}, _reason),
    do: normalize_close(:gen_tcp.close(socket))

  def close(%__MODULE__{transport: :ssl, socket: socket}, _reason),
    do: normalize_close(:ssl.close(socket))

  @impl true
  def handle_info({:tcp, socket, line}, %__MODULE__{transport: :gen_tcp, socket: socket}),
    do: {:data, nil, line}

  def handle_info({:ssl, socket, line}, %__MODULE__{transport: :ssl, socket: socket}),
    do: {:data, nil, line}

  def handle_info({:tcp_closed, socket}, %__MODULE__{transport: :gen_tcp, socket: socket}),
    do: {:closed, :transport_closed}

  def handle_info({:ssl_closed, socket}, %__MODULE__{transport: :ssl, socket: socket}),
    do: {:closed, :transport_closed}

  def handle_info({:tcp_error, socket, reason}, %__MODULE__{
        transport: :gen_tcp,
        socket: socket
      }),
      do: {:closed, {:transport_error, reason}}

  def handle_info({:ssl_error, socket, reason}, %__MODULE__{transport: :ssl, socket: socket}),
    do: {:closed, {:transport_error, reason}}

  def handle_info(_message, %__MODULE__{}), do: :unknown

  @doc false
  @spec type(t()) :: :gen_tcp | :ssl
  def type(%__MODULE__{transport: transport}), do: transport

  @doc false
  @spec tls_connect_options(map()) :: keyword()
  def tls_connect_options(config) do
    tls_options = Map.get(config, :tls_options, [])

    defaults = [
      verify: :verify_peer,
      server_name_indication:
        config
        |> Map.get(:sni, Map.fetch!(config, :host))
        |> String.to_charlist(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    defaults =
      if Enum.any?([:cacerts, :cacertfile], &Keyword.has_key?(tls_options, &1)) do
        defaults
      else
        Keyword.put(defaults, :cacerts, :public_key.cacerts_get())
      end

    Keyword.merge(defaults, tls_options)
  end

  defp tcp_options do
    [
      :binary,
      packet: :line,
      packet_size: Message.max_received_wire_bytes(),
      active: false
    ]
  end

  defp normalize_close(:ok), do: :ok
  defp normalize_close({:error, :closed}), do: :ok
  defp normalize_close(error), do: error
end
