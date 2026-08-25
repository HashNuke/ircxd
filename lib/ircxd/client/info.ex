defmodule Ircxd.Client.Info do
  @moduledoc """
  Secret-free snapshot of protocol state cached by an `Ircxd.Client` process.

  Reading a snapshot never sends IRC traffic. Adapter callbacks receive the
  same snapshot in their context so they do not need to call the client
  GenServer from inside its own process.
  """

  alias Ircxd.ISupport

  @enforce_keys [
    :status,
    :connected?,
    :registered?,
    :host,
    :port,
    :tls?,
    :transport,
    :desired_nick,
    :current_nick,
    :available_caps,
    :active_caps,
    :isupport,
    :casemapping
  ]
  defstruct @enforce_keys

  @type status :: :disconnected | :connected | :registered

  @type t :: %__MODULE__{
          status: status(),
          connected?: boolean(),
          registered?: boolean(),
          host: String.t(),
          port: :inet.port_number(),
          tls?: boolean(),
          transport: :gen_tcp | :ssl | nil,
          desired_nick: String.t(),
          current_nick: String.t() | nil,
          available_caps: %{optional(String.t()) => String.t() | true},
          active_caps: MapSet.t(String.t()),
          isupport: map(),
          casemapping: Ircxd.Casemapping.mapping()
        }

  @spec same_identifier?(t(), String.t(), String.t()) :: boolean()
  def same_identifier?(%__MODULE__{isupport: isupport}, left, right)
      when is_binary(left) and is_binary(right),
      do: ISupport.equal?(isupport, left, right)

  def same_identifier?(%__MODULE__{}, _left, _right), do: false

  @spec self_nick?(t(), String.t()) :: boolean()
  def self_nick?(%__MODULE__{current_nick: current_nick} = info, nick)
      when is_binary(current_nick) and is_binary(nick),
      do: same_identifier?(info, current_nick, nick)

  def self_nick?(%__MODULE__{}, _nick), do: false
end
