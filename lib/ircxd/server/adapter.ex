defmodule Ircxd.Server.Adapter do
  @moduledoc """
  Application-owned server integration contract.

  Adapters may authenticate accounts, consume committed domain events, answer
  application state queries, and observe the legacy published-message stream.
  All callbacks are serialized by the server's adapter worker except
  authentication, which runs in a bounded task.
  """

  alias Ircxd.Message
  alias Ircxd.Server.Event

  @type state :: term()
  @type context :: map()
  @type operation :: term()
  @type action :: term()
  @type query ::
          :users
          | :channels
          | {:channel, String.t()}
          | {:channels_for, String.t()}
          | {:channel_roles, String.t(), String.t()}
          | {:messages, String.t(), keyword()}

  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @callback handle_event(Event.t(), context(), state()) :: {:ok, state()}

  @callback handle_query(query(), context(), state()) ::
              {:ok, term(), state()} | {:error, term(), state()}

  @callback handle_operation(operation(), context(), state()) ::
              {:ok, term(), state()} | {:error, term(), state()}

  @callback authorize(action(), context(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @callback handle_command(Message.t(), context(), state()) ::
              {:unhandled, state()}
              | {:reply, [Message.t()], state()}
              | {:error, term(), state()}

  @callback handle_publish(Message.t(), map(), state()) :: {:ok, state()}

  @callback authenticate(String.t(), String.t(), map(), state()) ::
              {:ok, term(), state()} | {:error, term(), state()}

  @callback authentication_enabled?(state()) :: boolean()

  @optional_callbacks authenticate: 4,
                      authentication_enabled?: 1,
                      authorize: 3,
                      handle_command: 3,
                      handle_event: 3,
                      handle_query: 3,
                      handle_operation: 3,
                      handle_publish: 3
end
