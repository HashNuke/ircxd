defmodule Ircxd do
  @moduledoc """
  Ircxd is a small IRC client library for Elixir applications.

  The library exposes protocol parsing/serialization helpers and a supervised
  client process. Application-specific persistence and side effects are kept
  outside the library through callback events.
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
