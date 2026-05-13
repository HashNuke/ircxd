# ircxd Host Boundaries

`ircxd` is an IRC protocol library for Elixir applications. It owns protocol
parsing, serialization, connection state, capability negotiation, and event
emission. Host applications own product policy, persistence, and UI transport.

## Owned By `ircxd`

- IRC line parsing and serialization.
- TCP and implicit TLS client connection lifecycle.
- Registration, capability negotiation, SASL, and automatic `PING`/`PONG`.
- IRCv2/Modern IRC command helpers and typed events.
- IRCv3 stable parsing, helpers, and typed events where the feature is part of
  the client/server protocol.
- Scripted-server tests and local InspIRCd integration tests that prove protocol
  behavior at the IRC boundary.

## Owned By Host Applications

- Message storage, scrollback retention, indexing, and database schemas.
- Notification delivery, read state, unread counts, and mention policy.
- User account systems and secrets management.
- Channel and network configuration UX.
- STS policy persistence and upgrade enforcement across application restarts.
- DCC socket/file transfer policy, file writes, consent prompts, and bandwidth
  limits.
- WebSocket server lifecycle for Phoenix Channels, Cowboy, Bandit, or another
  stack.

## Event Delivery

Applications can consume events in either of these ways:

- Pass `notify: pid` to receive `{:ircxd, event}` messages.
- Pass `handler: {module, init_arg}` where `module` implements
  `Ircxd.Handler`.

The handler boundary is deliberately small:

```elixir
@callback init(term()) :: {:ok, term()}
@callback handle_event(term(), term()) :: {:ok, term()}
```

Handlers should translate protocol events into application effects. For
example, a Phoenix app can persist `{:privmsg, payload}` events, update unread
state for `{:mention, payload}`-style application events, or broadcast through a
Channel. Those storage and broadcast decisions should not be added to `ircxd`
core.

See `docs/embedding_events.md` for callback examples and persistence boundary
guidance.

See `docs/dcc_boundaries.md` for DCC event handling and transfer-policy
guidance.

## WebSocket Adapters

`Ircxd.WebSocket` validates IRCv3 WebSocket subprotocols and one-line payloads.
It does not run a WebSocket server. Host applications can call
`Ircxd.WebSocket.send_frame/4` and `Ircxd.WebSocket.close/3` with an adapter
that implements `Ircxd.WebSocket.Adapter`:

```elixir
@callback send_frame(state(), :binary | :text, binary()) :: :ok | {:error, term()}
@callback close(state(), term()) :: :ok | {:error, term()}
```

`close/2` is optional. `Ircxd.WebSocket.close/3` returns
`{:error, :unsupported_close}` for adapters that only support sending frames.

The bundled `Ircxd.WebSocket.MemoryAdapter` exists for tests and adapter-boundary
verification. Production Phoenix/Cowboy/Bandit adapters can live in the host app
or optional packages without coupling `ircxd` core to a specific web stack.

See `docs/websocket_adapters.md` for concrete adapter examples, including a
Phoenix Channels adapter shape.

## Test Expectations

Protocol behavior should be covered in `ircxd` with parser tests, scripted IRC
server tests, and local InspIRCd integration tests. Host-owned behavior should
be tested by the embedding app with its chosen database, notification system,
and WebSocket stack.
