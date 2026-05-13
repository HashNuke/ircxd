defmodule Ircxd.Handler do
  @moduledoc """
  Optional callback behaviour for applications embedding `Ircxd.Client`.

  Returning storage effects to the application keeps this library independent of
  any database or persistence model.
  """

  @callback init(term()) :: {:ok, term()}
  @callback handle_event(term(), term()) :: {:ok, term()}
end
