defmodule Ircxd.Server.Adapter do
  @moduledoc """
  Application-owned server integration contract.

  Adapters may authenticate accounts, consume committed domain events, answer
  application state queries, and observe outbound IRC messages.
  All callbacks are serialized by the server's adapter worker except
  authentication, which runs in a bounded task.
  """

  alias Ircxd.Message
  alias Ircxd.Server.Event

  @typedoc "Application state for one server adapter."
  @type state :: term()

  @typedoc "Server and actor data for one callback."
  @type context :: map()

  @typedoc "An application-owned state operation."
  @type operation :: term()

  @typedoc "A protocol action that needs an authorization decision."
  @type action :: term()

  @typedoc "A query supported by the built-in ETS adapter."
  @type query ::
          :users
          | :channels
          | {:channel, String.t()}
          | {:channels_for, String.t()}
          | {:channel_roles, String.t(), String.t()}
          | {:messages, String.t(), keyword()}

  @doc "Initializes the adapter state from the configured argument."
  @callback init(term()) :: {:ok, state()} | {:error, term()}

  @doc "Consumes one committed server event and returns the next adapter state."
  @callback handle_event(Event.t(), context(), state()) :: {:ok, state()}

  @doc "Handles an application query from `Ircxd.Server.query/2`."
  @callback handle_query(query(), context(), state()) ::
              {:ok, term(), state()} | {:error, term(), state()}

  @doc "Handles an application operation from `Ircxd.Server.execute/2`."
  @callback handle_operation(operation(), context(), state()) ::
              {:ok, term(), state()} | {:error, term(), state()}

  @doc "Allows or rejects a protocol action before the server changes state."
  @callback authorize(action(), context(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc "Handles an IRC command that the protocol engine does not recognize."
  @callback handle_command(Message.t(), context(), state()) ::
              {:unhandled, state()}
              | {:reply, [Message.t()], state()}
              | {:error, term(), state()}

  @doc "Observes one outbound IRC message, including numerics."
  @callback handle_publish(Message.t(), map(), state()) :: {:ok, state()}

  @doc "Verifies SASL credentials and returns an application account."
  @callback authenticate(String.t(), String.t(), map(), state()) ::
              {:ok, term(), state()} | {:error, term(), state()}

  @doc "Returns `true` when the initialized adapter can authenticate accounts."
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
