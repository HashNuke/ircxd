# Client usage and adapters

`Ircxd.Client` is a supervised IRC client process. It owns one TCP or TLS
connection, performs IRC registration and capability negotiation, answers
server `PING` messages, exposes command helpers, and turns incoming protocol
messages into Elixir events.

Applications can receive those events as process messages, through a stateful
`Ircxd.Client.Adapter`, or through both mechanisms. This guide covers the
complete client lifecycle and then the adapter integration contract.

## Starting and supervising a client

For an ad hoc connection, call `Ircxd.start_link/1`, which delegates to
`Ircxd.Client.start_link/1`:

```elixir
{:ok, client} =
  Ircxd.start_link(
    host: "irc.libera.chat",
    port: 6697,
    tls: true,
    nick: "my-app",
    username: "my-app",
    realname: "My Elixir App",
    caps: ["server-time", "message-tags"],
    notify: self()
  )
```

Starting the process schedules the connection attempt; it does not mean IRC
registration has completed. Wait for the `:registered` event before sending
commands that require a registered client:

```elixir
receive do
  {:ircxd, :registered} -> Ircxd.Client.join(client, "#elixir")
  {:ircxd, {:connect_error, reason}} -> {:error, reason}
end
```

In an application, supervise the client and give it a registered process name:

```elixir
children = [
  Supervisor.child_spec(
    {Ircxd.Client,
     name: MyApp.IrcClient,
     host: "irc.libera.chat",
     port: 6697,
     tls: true,
     nick: "my-app",
     caps: ["server-time"],
     adapter: {MyApp.IrcClientAdapter, %{account_id: 42}},
     reconnect: true},
    id: :primary_irc_client
  )
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The generated `Ircxd.Client` child specification restarts a client that exits.
Use a distinct child `:id` and, when needed, a distinct `:name` for every
connection supervised by the same application.

## Connection options

The core identity and transport options are:

| Option | Required/default | Purpose |
| --- | --- | --- |
| `:host` | Required | IRC server hostname or address. |
| `:port` | `6697` with TLS, otherwise `6667` | Remote listener port. |
| `:tls` | `false` | Use implicit TLS. |
| `:sni` | Value of `:host` | TLS SNI and hostname-verification name. |
| `:tls_options` | `[]` | Additional Erlang `:ssl.connect/4` options. |
| `:nick` | Required | Initial nickname. |
| `:username` | Value of `:nick` | Username sent during registration. |
| `:realname` | Value of `:nick` | Real name sent during registration. |
| `:nick_retry_fun` | Appends `_` | Function called after a nickname collision. |
| `:name` | None | Optional GenServer registration name. |

Client behavior and integration options are:

| Option | Default | Purpose |
| --- | --- | --- |
| `:caps` | `[]` | IRCv3 capabilities to request during registration. |
| `:notify` | `nil` | PID that receives `{:ircxd, event}` messages. |
| `:adapter` | `nil` | `{module, init_arg}` implementing `Ircxd.Client.Adapter`. |
| `:reconnect` | `false` | Reconnect policy after an established transport closes. |
| `:password` | `nil` | Server password sent with `PASS` before registration. |
| `:sasl` | `nil` | One SASL mechanism or an ordered fallback list. |
| `:sasl_failure` | `:continue` | Use `:continue` or `:abort` after the final SASL failure. |
| `:allow_insecure_auth` | `false` | Permit credential-bearing commands over cleartext TCP. |
| `:webirc` | `nil` | Keyword options used to send `WEBIRC` before registration. |
| `:msgid_dedupe` | `false` | Use `:mark` to identify repeated IRCv3 message IDs. |
| `:server_time_order` | `false` | Buffer server-time events with `:manual` or `[flush_after: milliseconds]`. |

The legacy `handler: {Module, init_arg}` option is described in the migration
section below. Do not configure it together with `:adapter`.

## Receiving events

With `notify: pid`, every event arrives as `{:ircxd, event}`. Common lifecycle
and messaging events include:

| Event | Meaning |
| --- | --- |
| `{:connected, details}` | The TCP or TLS connection was established. |
| `:registered` | IRC registration and initial capability negotiation completed. |
| `:disconnected` | The established transport closed. |
| `{:reconnecting, details}` | A reconnect was scheduled. |
| `{:connect_error, reason}` | The connection attempt failed and the client stopped. |
| `{:join, details}`, `{:part, details}`, `{:quit, details}` | Channel or user lifecycle activity. |
| `{:privmsg, details}`, `{:notice, details}` | A normalized incoming message. |
| `{:irc_error, details}` or `{:error, details}` | A numeric or protocol error from the server. |
| `{:message, %Ircxd.Message{}}` | Parsed IRC input for consumers that need wire-level detail. |

For example:

```elixir
receive do
  {:ircxd, {:privmsg, %{nick: nick, target: target, body: body}}} ->
    Logger.info("#{nick} said #{inspect(body)} in #{target}")
end
```

IRCv3 features and server numerics produce additional typed events for
capabilities, accounts, presence, batches, labels, history, metadata, standard
replies, and server queries. Consult the `Ircxd.Client` module documentation
for the full public API and use `{:message, message}` when an extension has no
specialized event.

Normalized and raw-message events describe the same incoming traffic. Choose
which representation to persist so that handling both does not create
duplicates.

## Sending commands

`Ircxd.Client` provides focused helpers for common IRC and IRCv3 operations:

```elixir
:ok = Ircxd.Client.join(client, "#elixir")
:ok = Ircxd.Client.privmsg(client, "#elixir", "hello")
:ok = Ircxd.Client.action(client, "#elixir", "waves")
:ok = Ircxd.Client.reply(client, "#elixir", "agreed", "parent-msgid")
:ok = Ircxd.Client.away(client, "deploying")
:ok = Ircxd.Client.whois(client, "alice")
```

A successful return means the command was validated and written to the
transport; acceptance by the remote server is reported later through events.
Calls made before a connection exists return `{:error, :not_connected}`.
Helpers may also reject invalid parameters, oversized lines, credential
commands on cleartext connections, or operations whose required capability is
not active.

Use the escape hatches when no dedicated helper exists:

```elixir
:ok = Ircxd.Client.raw(client, "MAP", [])
:ok = Ircxd.Client.raw_tagged(client, "TAGMSG", ["#elixir"], %{"+typing" => "active"})

:ok =
  Ircxd.Client.transmit(client, %Ircxd.Message{
    command: "NOTICE",
    params: ["alice", "hello"]
  })
```

Raw commands still pass through command-shape, CR/LF injection, wire-size,
UTF-8, authentication, tag, and capability validation.

## Capabilities

Pass `caps: [...]` to request capabilities during initial negotiation. The
client emits `{:cap_ls, capabilities}`, `{:cap_ack, capabilities}`, and
`{:cap_nak, capabilities}` events as the server responds.

Capabilities can also be changed after registration:

```elixir
:ok = Ircxd.Client.request_capabilities(client, ["echo-message"])
:ok = Ircxd.Client.disable_capabilities(client, ["echo-message"])
:ok = Ircxd.Client.cap_list(client)
```

The first two functions validate against the capabilities advertised or
enabled by the current server. Their successful return means a `CAP REQ` was
sent; wait for `:cap_ack` or `:cap_nak` to learn the server's decision. An IRCv3
helper such as `chathistory_latest/4` returns an error if its required
capability is not active.

## TLS and authentication

TLS clients verify the certificate chain and hostname by default against the
operating-system CA store. `:sni` defaults to `:host`; override it when
connecting by IP address or through a test fixture while validating a
certificate issued for another hostname:

```elixir
tls: true,
sni: "irc.example.test",
tls_options: [cacertfile: "/path/to/private-ca.pem"]
```

Disabling verification with `tls_options: [verify: :verify_none]` should be
limited to isolated development fixtures.

The client supports a server `PASS` value and these SASL forms:

```elixir
sasl: {:plain, "account", "secret"}
sasl: {:external, "account"}
sasl: {:scram_sha_256, "account", "secret"}
```

An ordered list enables mechanism fallback when the server advertises more
than one supported mechanism:

```elixir
sasl: [
  {:external, "account"},
  {:scram_sha_256, "account", "secret"},
  {:plain, "account", "secret"}
]
```

After the final mechanism fails, `sasl_failure: :continue` completes IRC
registration without SASL and `sasl_failure: :abort` stops the client. SASL,
`PASS`, `OPER`, account registration, and `WEBIRC` are blocked on cleartext TCP
unless `allow_insecure_auth: true` is set explicitly. Prefer verified TLS
instead of enabling that override.

## Reconnection

Reconnection is disabled by default. `reconnect: true` retries indefinitely
with a one-second delay after an established transport closes. A bounded policy
can specify attempts and delay in milliseconds:

```elixir
reconnect: [max_attempts: 5, delay: 2_000]
```

The same client process and adapter state survive a reconnect. Connection,
registration, capability, batch, label, message-ID, and server-time state are
reset before the next attempt. Observe `:disconnected`, `:reconnecting`, and a
new `:registered` event before resuming commands.

An initial connection failure emits `{:connect_error, reason}` and stops the
client. Use an OTP supervisor to restart failures that occur before a transport
has been established.

## Implementing an adapter

`Ircxd.Client.Adapter` is the application integration boundary for a client
connection. It receives the same normalized events exposed through `:notify`,
with stateful callback handling for persistence, application broadcasts,
metrics, bot behavior, or other side effects.

Client and server integrations use parallel names and configuration:

| Component | Behavior | Option | Primary event callback |
| --- | --- | --- | --- |
| IRC client | `Ircxd.Client.Adapter` | `adapter: {Module, init_arg}` | `handle_event/3` |
| IRC server | `Ircxd.Server.Adapter` | `adapter: {Module, init_arg}` | `handle_event/3` |

The client adapter reacts to events received from a remote IRC server. The
server adapter projects and governs activity accepted by an embedded
`Ircxd.Server`. See the [server adapter guide](server-adapters.md) for its
contract and built-in ETS implementation.

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

account_id = 42

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

The `:notify` and `:adapter` options may be used together. Notification
messages are sent first, then the adapter callback runs. Applications should
avoid persisting both forms of the same event unless that duplication is
intentional.

Client adapters do not receive passwords passed to `PASS` or SASL helper
configuration. Avoid logging raw messages if a remote server sends sensitive
material in an ordinary IRC message.

### Ordering, failure, and performance

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
