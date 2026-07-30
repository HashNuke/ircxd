defmodule Ircxd.Server.AdapterWorker do
  @moduledoc false

  use GenServer

  alias Ircxd.Message

  def start(module, arg, authentication_timeout),
    do: GenServer.start(__MODULE__, {module, arg, authentication_timeout})

  def publish(pid, message, metadata),
    do: GenServer.cast(pid, {:publish, message, metadata})

  def authenticate(pid, username, password, metadata),
    do: GenServer.call(pid, {:authenticate, username, password, metadata}, :infinity)

  def authentication_enabled?(pid), do: GenServer.call(pid, :authentication_enabled?)

  @impl true
  def init({module, arg, authentication_timeout}) do
    case module.init(arg) do
      {:ok, callback_state} ->
        {:ok, authentication_supervisor} = Task.Supervisor.start_link(max_children: 1)

        {:ok,
         %{
           module: module,
           callback_state: callback_state,
           authentication_timeout: authentication_timeout,
           authentication_supervisor: authentication_supervisor,
           authentication_queue: [],
           authentication_task: nil
         }}

      {:error, reason} ->
        {:stop, {:adapter_init_failed, reason}}

      other ->
        {:stop, {:adapter_init_failed, {:invalid_return, other}}}
    end
  end

  @impl true
  def handle_call(:authentication_enabled?, _from, state) do
    {:reply, function_exported?(state.module, :authenticate, 4), state}
  end

  def handle_call({:authenticate, username, password, metadata}, from, state) do
    if function_exported?(state.module, :authenticate, 4) do
      request = %{from: from, username: username, password: password, metadata: metadata}
      state = %{state | authentication_queue: state.authentication_queue ++ [request]}
      {:noreply, maybe_start_authentication(state)}
    else
      {:reply, {:error, :authentication_not_configured}, state}
    end
  end

  @impl true
  def handle_cast({:publish, %Message{} = message, metadata}, state) do
    if function_exported?(state.module, :handle_publish, 3) do
      callback_state = invoke_publish(state.module, message, metadata, state.callback_state)
      {:noreply, %{state | callback_state: callback_state}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{authentication_task: %{ref: ref} = task} = state) do
    Process.cancel_timer(task.timer)
    Process.demonitor(ref, [:flush])
    {request, state} = finish_authentication(state, result)
    GenServer.reply(request.from, authentication_reply(result))
    {:noreply, maybe_start_authentication(state)}
  end

  def handle_info(
        {:authentication_timeout, ref},
        %{authentication_task: %{ref: ref} = task} = state
      ) do
    Task.Supervisor.terminate_child(task.supervisor, task.pid)
    Process.demonitor(ref, [:flush])
    {request, state} = finish_authentication(state, {:error, :authentication_timeout, nil})
    GenServer.reply(request.from, {:error, :authentication_timeout})
    {:noreply, maybe_start_authentication(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{authentication_task: %{ref: ref} = task} = state
      ) do
    Process.cancel_timer(task.timer)
    {request, state} = finish_authentication(state, {:error, :authentication_failed, nil})
    GenServer.reply(request.from, {:error, {:authentication_task_failed, reason}})
    {:noreply, maybe_start_authentication(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:authentication_timeout, _ref}, state), do: {:noreply, state}

  defp maybe_start_authentication(%{authentication_task: nil, authentication_queue: []} = state),
    do: state

  defp maybe_start_authentication(%{authentication_task: task} = state) when not is_nil(task),
    do: state

  defp maybe_start_authentication(%{authentication_task: nil} = state) do
    [request | queue] = state.authentication_queue
    module = state.module
    callback_state = state.callback_state
    supervisor = state.authentication_supervisor

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        invoke_authentication(
          module,
          request.username,
          request.password,
          request.metadata,
          callback_state
        )
      end)

    timer =
      Process.send_after(
        self(),
        {:authentication_timeout, task.ref},
        state.authentication_timeout
      )

    %{
      state
      | authentication_queue: queue,
        authentication_task: %{
          supervisor: supervisor,
          pid: task.pid,
          ref: task.ref,
          timer: timer,
          request: request
        }
    }
  end

  defp finish_authentication(state, result) do
    task = state.authentication_task
    state = %{state | authentication_task: nil}

    case result do
      {:ok, _account, callback_state} ->
        {task.request, %{state | callback_state: callback_state}}

      {:error, _reason, callback_state} when not is_nil(callback_state) ->
        {task.request, %{state | callback_state: callback_state}}

      _ ->
        {task.request, state}
    end
  end

  defp invoke_publish(module, message, metadata, callback_state) do
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

  defp invoke_authentication(module, username, password, metadata, callback_state) do
    result =
      try do
        module.authenticate(username, password, metadata, callback_state)
      rescue
        _error -> {:error, :authentication_failed, callback_state}
      catch
        _kind, _reason -> {:error, :authentication_failed, callback_state}
      end

    case result do
      {:ok, _account, _new_state} -> result
      {:error, _reason, _new_state} -> result
      _other -> {:error, :authentication_failed, callback_state}
    end
  end

  defp authentication_reply({:ok, account, _state}), do: {:ok, account}
  defp authentication_reply({:error, reason, _state}), do: {:error, reason}
  defp authentication_reply(_result), do: {:error, :authentication_failed}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.authentication_supervisor) do
      Supervisor.stop(state.authentication_supervisor)
    end

    :ok
  end
end
