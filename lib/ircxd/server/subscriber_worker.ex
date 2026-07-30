defmodule Ircxd.Server.SubscriberWorker do
  @moduledoc false

  use GenServer

  alias Ircxd.Message

  def start(module, arg), do: GenServer.start(__MODULE__, {module, arg})

  @impl true
  def init({module, arg}) do
    case module.init(arg) do
      {:ok, callback_state} ->
        {:ok, %{module: module, callback_state: callback_state}}

      {:error, reason} ->
        {:stop, {:subscriber_init_failed, reason}}

      other ->
        {:stop, {:subscriber_init_failed, {:invalid_return, other}}}
    end
  end

  @impl true
  def handle_cast({:publish, %Message{} = message, metadata}, state) do
    callback_state = invoke(state.module, message, metadata, state.callback_state)
    {:noreply, %{state | callback_state: callback_state}}
  end

  defp invoke(module, message, metadata, callback_state) do
    try do
      case module.handle_publish(message, metadata, callback_state) do
        {:ok, new_callback_state} -> new_callback_state
        _other -> callback_state
      end
    rescue
      _error -> callback_state
    catch
      _kind, _reason -> callback_state
    end
  end
end
