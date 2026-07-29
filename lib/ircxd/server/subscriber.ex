defmodule Ircxd.Server.Subscriber do
  @moduledoc """
  Contract for receiving messages published by an `Ircxd.Server`.

  Subscribers are owned by the server process and should keep their callback
  lightweight. Persistence and other application side effects remain outside
  the IRC protocol processes.
  """

  alias Ircxd.Message

  @callback init(term()) :: {:ok, term()}
  @callback handle_publish(Message.t(), map(), term()) :: {:ok, term()}
end
