defmodule Ircxd.Server.Connection do
  @moduledoc false

  use GenServer

  alias Ircxd.Message

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)

    {:ok,
     %{
       socket: socket,
       server: Keyword.fetch!(opts, :server),
       server_name: Keyword.fetch!(opts, :server_name),
       auth_required?: Keyword.get(opts, :auth_required?, false),
       authenticated?: false,
       account: nil,
       nick: nil,
       username: nil,
       realname: nil,
       registered?: false
     }}
  end

  @impl true
  def handle_info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: true)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    case Message.parse(line) do
      {:ok, message} -> handle_message(message, state)
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
  catch
    :error, :closed -> :ok
  end

  defp handle_message(%Message{command: "CAP", params: ["LS" | _]}, state) do
    caps = if(state.auth_required?, do: "sasl", else: "")
    send_message(state, "CAP", ["*", "LS", caps])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "CAP", params: ["REQ", caps]}, state) do
    if state.auth_required? and String.split(caps) == ["sasl"],
      do: send_message(state, "CAP", ["*", "ACK", "sasl"])

    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: ["PLAIN"]}, state) do
    send_message(state, "AUTHENTICATE", ["+"])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "AUTHENTICATE", params: [payload]}, state)
       when state.auth_required? do
    case decode_plain(payload) do
      {:ok, username, password} ->
        metadata = %{server: state.server_name, connection: self(), nick: state.nick}

        case Ircxd.Server.authenticate(state.server, username, password, metadata) do
          {:ok, account} ->
            send_message(state, "903", [state.nick, "SASL authentication successful"])
            maybe_register(%{state | authenticated?: true, account: account})

          {:error, _reason} ->
            send_message(state, "904", [state.nick, "SASL authentication failed"])
            {:noreply, state}
        end

      :error ->
        send_message(state, "904", [state.nick, "Invalid SASL credentials"])
        {:noreply, state}
    end
  end

  defp handle_message(%Message{command: "NICK", params: [nick]}, state) do
    state = %{state | nick: nick}
    maybe_register(state)
  end

  defp handle_message(
         %Message{command: "USER", params: [username, _mode, _unused, realname]},
         state
       ) do
    state = %{state | username: username, realname: realname}
    maybe_register(state)
  end

  defp handle_message(%Message{command: "PING", params: params}, state) do
    send_message(state, "PONG", params)
    {:noreply, state}
  end

  defp handle_message(_message, state), do: {:noreply, state}

  defp maybe_register(%{registered?: true} = state), do: {:noreply, state}

  defp maybe_register(%{auth_required?: true, authenticated?: false} = state),
    do: {:noreply, state}

  defp maybe_register(%{nick: nick, username: username} = state)
       when is_binary(nick) and is_binary(username) do
    send_message(state, "001", [nick, "Welcome to Ircxd"])
    send_message(state, "002", [nick, "Your host is #{state.server_name}"])
    send(state.server, {:server_client_registered, self(), nick})
    {:noreply, %{state | registered?: true}}
  end

  defp maybe_register(state), do: {:noreply, state}

  defp send_message(state, command, params) do
    message = %Message{command: command, params: params}
    metadata = %{server: state.server_name, connection: self(), nick: state.nick}
    Ircxd.Server.publish(state.server, message, metadata)
    :gen_tcp.send(state.socket, Message.serialize(message))
  end

  defp decode_plain(payload) do
    with {:ok, decoded} <- Base.decode64(payload),
         [_, username, password] <- String.split(decoded, <<0>>, parts: 3) do
      {:ok, username, password}
    else
      _ -> :error
    end
  end
end
