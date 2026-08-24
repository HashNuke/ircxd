defmodule Ircxd do
  @moduledoc """
  Ircxd is an IRC server and client library for Elixir applications.

  The library exposes protocol parsing/serialization helpers, a supervised
  client process, and an embeddable server. Application-specific persistence
  and side effects integrate through `Ircxd.Client.Adapter` and
  `Ircxd.Server.Adapter`.
  """

  alias Ircxd.Client
  alias Ircxd.Message

  @doc """
  Starts an IRC client process.

  See `Ircxd.Client.start_link/1` for supported options.
  """
  defdelegate start_link(opts), to: Client

  @doc """
  Parses one IRC line into an `Ircxd.Message`.
  """
  defdelegate parse(line), to: Message

  @doc """
  Serializes an `Ircxd.Message` or command tuple into an IRC line.
  """
  defdelegate serialize(message), to: Message
end
