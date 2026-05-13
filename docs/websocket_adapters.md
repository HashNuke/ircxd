# WebSocket Adapter Guide

`ircxd` implements the IRCv3 WebSocket protocol boundary without owning a
WebSocket server. Host applications provide a small adapter that knows how to
send frames through their chosen stack.

The core contract is `Ircxd.WebSocket.Adapter`:

```elixir
@callback send_frame(state(), :binary | :text, binary()) :: :ok | {:error, term()}
@callback close(state(), term()) :: :ok | {:error, term()}
```

`close/2` is optional. If an adapter does not implement it,
`Ircxd.WebSocket.close/3` returns `{:error, :unsupported_close}`.

## Phoenix Channels

A Phoenix app can keep the Phoenix dependency in the app and expose a small
adapter module:

```elixir
defmodule MyApp.IrcWebSocketAdapter do
  @behaviour Ircxd.WebSocket.Adapter

  @impl true
  def send_frame(socket, :text, payload) do
    Phoenix.Channel.push(socket, "irc:line", %{mode: "text", payload: payload})
    :ok
  end

  def send_frame(socket, :binary, payload) do
    Phoenix.Channel.push(socket, "irc:line", %{mode: "binary", payload: payload})
    :ok
  end

  @impl true
  def close(socket, reason) do
    Phoenix.Channel.push(socket, "irc:close", %{reason: inspect(reason)})
    :ok
  end
end
```

The channel remains responsible for authentication, topic authorization, and
mapping browser events to IRC client calls. `ircxd` should only receive IRC
lines or validated client actions from that channel.

Outbound IRC events can be encoded and sent like this:

```elixir
Ircxd.WebSocket.send_frame(
  MyApp.IrcWebSocketAdapter,
  socket,
  %Ircxd.Message{command: "PRIVMSG", params: ["#elixir", "hello"]},
  :text
)
```

Inbound browser payloads can be decoded before passing to application logic:

```elixir
case Ircxd.WebSocket.decode_message(payload, :text) do
  {:ok, message} -> handle_irc_message(socket, message)
  {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
end
```

## Process-backed Adapter

For tests or custom socket processes, the bundled
`Ircxd.WebSocket.MemoryAdapter` sends messages to a process:

```elixir
:ok =
  Ircxd.WebSocket.send_frame(
    Ircxd.WebSocket.MemoryAdapter,
    self(),
    "PING irc.example.test",
    :text
  )

receive do
  {:ircxd_websocket_frame, :text, "PING irc.example.test"} -> :ok
end
```

## Ownership Boundary

The host application owns:

- WebSocket connection lifecycle.
- Browser authentication and authorization.
- Mapping Phoenix topics, Cowboy handlers, or Bandit sockets to IRC clients.
- Message persistence, unread state, and notification delivery.

`ircxd` owns:

- IRCv3 WebSocket subprotocol names.
- One IRC line per WebSocket message validation.
- IRC wire-size checks.
- Text-frame UTF-8 validation.
- Adapter dispatch.
