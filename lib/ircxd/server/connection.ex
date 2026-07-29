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
       capabilities: Keyword.fetch!(opts, :capabilities),
       password: Keyword.get(opts, :password),
       password_authenticated?: is_nil(Keyword.get(opts, :password)),
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

  def handle_info({:server_send, %Message{} = message}, state) do
    :ok = :gen_tcp.send(state.socket, Message.serialize(message))
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
    caps = Enum.join(state.capabilities, " ")
    send_message(state, "CAP", ["*", "LS", caps])
    {:noreply, state}
  end

  defp handle_message(%Message{command: "CAP", params: ["REQ", caps]}, state) do
    requested = String.split(caps, " ", trim: true)

    if requested != [] and Enum.all?(requested, &(&1 in state.capabilities)),
      do: send_message(state, "CAP", ["*", "ACK", Enum.join(requested, " ")])

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

  defp handle_message(%Message{command: "PASS", params: [password]}, state) do
    case Ircxd.Server.verify_password(state.server, password) do
      :ok ->
        maybe_register(%{state | password_authenticated?: true})

      {:error, :invalid_password} ->
        send_message(state, "464", [state.nick || "*", "Password incorrect"])
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

  defp handle_message(%Message{command: command} = message, state)
       when command in ["JOIN", "NAMES", "PART", "PRIVMSG", "NOTICE", "TAGMSG", "TOPIC"] do
    Ircxd.Server.command(state.server, self(), message)
    {:noreply, state}
  end

  defp handle_message(%Message{command: "QUIT"} = message, state) do
    Ircxd.Server.command(state.server, self(), message)
    {:stop, :normal, state}
  end

  defp handle_message(_message, state), do: {:noreply, state}

  defp maybe_register(%{registered?: true} = state), do: {:noreply, state}

  defp maybe_register(%{auth_required?: true, authenticated?: false} = state),
    do: {:noreply, state}

  defp maybe_register(%{password_authenticated?: false} = state), do: {:noreply, state}

  defp maybe_register(%{nick: nick, username: username} = state)
       when is_binary(nick) and is_binary(username) do
    case Ircxd.Server.register(state.server, self(), nick) do
      :ok ->
        send_message(state, "001", [nick, "Welcome to Ircxd"])
        send_message(state, "002", [nick, "Your host is #{state.server_name}"])
        {:noreply, %{state | registered?: true}}

      {:error, :nick_in_use} ->
        send_message(state, "433", [nick, nick, "Nickname is already in use"])
        {:noreply, state}
    end
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
