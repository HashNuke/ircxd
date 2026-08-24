# Client adapters

`Ircxd.Client.Adapter` is the application integration boundary for an IRC
client connection. It receives the same normalized events exposed through the
client's `:notify` option, with stateful callback handling for persistence,
application broadcasts, metrics, bot behavior, or other side effects.

Client and server integrations use parallel names and configuration:

| Component | Behavior | Option | Primary event callback |
| --- | --- | --- | --- |
| IRC client | `Ircxd.Client.Adapter` | `adapter: {Module, init_arg}` | `handle_event/3` |
| IRC server | `Ircxd.Server.Adapter` | `adapter: {Module, init_arg}` | `handle_event/3` |

The client adapter reacts to events received from a remote IRC server. The
server adapter projects and governs activity accepted by an embedded
`Ircxd.Server`. See `docs/server-adapters.md` for the server contract and its
built-in ETS implementation.

## Implementing an adapter

```elixir
defmodule MyApp.IrcClientAdapter do
  @behaviour Ircxd.Client.Adapter

  @impl true
  def init(account_id), do: {:ok, %{account_id: account_id}}

  @impl true
  def handle_event({:privmsg, message}, context, state) do
    MyApp.Messages.store_incoming(state.account_id, context, message)
    {:ok, state}
  end

  def handle_event(_event, _context, state), do: {:ok, state}
end

{:ok, client} =
  Ircxd.Client.start_link(
    host: "irc.example.test",
    port: 6697,
    tls: true,
    nick: "my-app",
    adapter: {MyApp.IrcClientAdapter, account_id}
  )
```

The callback contract is deliberately small:

| Callback | Purpose | Return |
| --- | --- | --- |
| `init/1` | Initialize application callback state. | `{:ok, state}` or `{:error, reason}` |
| `handle_event/3` | Consume one normalized client event. | `{:ok, state}` |

The event context contains:

| Key | Meaning |
| --- | --- |
| `:client` | The client process PID. |
| `:host` | Configured remote host. |
| `:port` | Configured remote port. |
| `:tls?` | Whether the connection uses implicit TLS. |
| `:nick` | The client's current nickname at event time. |

Client adapter state belongs to one client process. Start a separate adapter
instance for each connection; use an application-owned database or registry
when state must be shared across clients.

## Events and raw messages

Events are normalized tuples such as `:registered`, `{:connected, details}`,
`{:join, details}`, `{:privmsg, details}`, `{:notice, details}`, and
`{:irc_error, details}`. Parsed traffic is also exposed as
`{:message, %Ircxd.Message{}}`, so an adapter can retain the normalized event,
the protocol message, or both. IRCv3 and command-specific events carry the
same payloads delivered by `notify: pid`.

The `:notify` and `:adapter` options may be used together. Notification
messages are sent first, then the adapter callback runs. Applications should
avoid persisting both forms of the same event unless that duplication is
intentional.

Client adapters do not receive passwords passed to `PASS` or SASL helper
configuration. Avoid logging raw messages if a remote server sends sensitive
material in an ordinary IRC message.

## Ordering, failure, and performance

The client invokes `handle_event/3` synchronously in its GenServer, in protocol
order. Updated callback state is used for the next event. Keep the callback
fast: a slow database call also delays socket processing and may contribute to
mailbox growth. For slow or retryable work, enqueue a compact event to an
application-supervised worker or durable outbox.

An invalid callback return retains the previous state. Adapter initialization
failure stops client startup as `{:adapter_init_failed, reason}`. Do not use the
callback state as the only copy of durable data; it ends with the client
process.

## Migrating from `Ircxd.Handler`

`Ircxd.Handler` and the `handler: {Module, init_arg}` option remain supported
for compatibility. New code should use `Ircxd.Client.Adapter` and `:adapter`.
The migration adds a context argument:

```elixir
# Legacy
def handle_event(event, state), do: {:ok, state}

# Current
def handle_event(event, context, state), do: {:ok, state}
```

Do not configure both `:handler` and `:adapter` on the same client. Startup
will fail with `:conflicting_adapter_and_handler`, which prevents an event from
being applied twice accidentally.
