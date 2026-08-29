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

See `Ircxd.Client.start_link/1` for all client options.

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
| `:events` | `:legacy` | Event delivery as `:legacy`, `:envelope`, or `:both`. |
| `:reconnect` | `false` | Reconnect policy after an established transport closes. |
| `:password` | `nil` | Server password sent with `PASS` before registration. |
| `:sasl` | `nil` | One SASL mechanism or an ordered fallback list. |
| `:sasl_failure` | `:continue` | Use `:continue` or `:abort` after the final SASL failure. |
| `:allow_insecure_auth` | `false` | Permit credential-bearing commands over cleartext TCP. |
| `:webirc` | `nil` | Keyword options used to send `WEBIRC` before registration. |
| `:msgid_dedupe` | `false` | Use `:mark` to identify repeated IRCv3 message IDs. |
| `:server_time_order` | `false` | Buffer server-time events with `:manual` or `[flush_after: milliseconds]`. |

Server-time ordering delays publication, not IRC protocol bookkeeping.
Timestamped batch members are attached to and collected into their active
batch as they arrive. An untimed batch close can therefore publish complete
labeled, multiline, ISUPPORT, metadata, netjoin, or netsplit aggregates; a
later manual or timed flush publishes each buffered member and its `:batched`
relationship with the batch context captured on arrival.
Direct labeled-request acknowledgment and completion also advance on arrival,
so a disconnect cannot mark an already-observed response as failed. The
timestamped content event and its `:labeled_response` relationship remain
buffered until publication, without repeating lifecycle transitions.

## Receiving events

With `notify: pid`, every event arrives as `{:ircxd, event}`. Common lifecycle
and messaging events include:

| Event | Meaning |
| --- | --- |
| `{:connected, details}` | The TCP or TLS connection was established. |
| `:registered` | IRC registration and initial capability negotiation completed. |
| `:disconnected` | The established transport closed. |
| `{:disconnect, details}` | Explains whether the close was intentional and whether reconnect was scheduled. |
| `{:reconnecting, details}` | A reconnect was scheduled. |
| `{:connect_error, reason}` | A connection attempt failed; the reconnect policy determines whether another attempt follows. |
| `{:reconnect_exhausted, details}` | A bounded reconnect policy used its final attempt and the client stopped normally. |
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

### Labels, batches, and request lifecycle

A normalized event such as `{:whois_user, details}` or `{:names, details}` is
the content representation of one server reply. Its details include
`:raw_message`, `:label`, and `:batch` metadata when applicable. Persist or
display that normalized event once.

The client also emits relationship and lifecycle views:

| Event | Meaning |
| --- | --- |
| `{:labeled_response, details}` | Correlates a label with a single event or completed batch; it is not another content row. |
| `{:batched, details}` | Relates an already-emitted normalized event to a server batch. |
| `{:labeled_request, details}` | Reports `:sent`, `:acknowledged`, `:completed`, or `:failed` request state. |
| `{:ack, details}` | The server's sole logical response for a labeled command that normally has no content response. |

For example, persist the `:whois_user` event and use `:labeled_response` only
to mark the matching application request:

```elixir
def handle_event({:whois_user, details}, _context, state) do
  {:ok, persist_result_once(state, details)}
end

def handle_event({:labeled_response, %{label: label}}, _context, state) do
  {:ok, correlate_request(state, label)}
end
```

A labeled response is exactly one logical response: a direct message, an
ACK-only completion, or a batch. Labels are opaque values. Missing, incomplete,
or late responses remain possible, so application timeouts are still required.
Successful response boundaries produce `status: :completed`. Correlated IRC
error/rejection events and standard `FAIL` replies instead produce
`status: :failed`; `:reason` contains the normalized failure event, while
transport failures retain their transport reason. This classification applies
to both direct responses and failures collected inside labeled batches.

### Cached state and self identity

`Ircxd.Client.connection_info/1` returns a secret-free snapshot of the state
the client is currently using without sending IRC traffic:

```elixir
info = Ircxd.Client.connection_info(client)
info.registered?
info.current_nick
info.active_caps
info.isupport
```

The snapshot changes after registration, capability and ISUPPORT updates, a
confirmed self NICK, and disconnect/reconnect transitions. It never contains
PASS, SASL, OPER, WEBIRC, or account-registration credentials. Adapter
callbacks receive the same snapshot as `context.client_info`; they must use
that value instead of synchronously calling the client GenServer from inside
`c:Ircxd.Client.Adapter.handle_event/3`.

Source-bearing normalized events include `:source_self?`. Events with a nick
target, including KICK, MODE, PRIVMSG, NOTICE, and TAGMSG, also include
`:target_self?`. These flags use negotiated CASEMAPPING and describe identity
when the event was processed. A self NICK updates `context.client_info` before
the NICK event is delivered, while the event's `:source_self?` flag is
calculated against the previous confirmed nick.

External processes can also use `Ircxd.Client.self_nick?/2` and
`Ircxd.Client.same_identifier?/3`. For asynchronous persistence, prefer the
event flags because a later NICK may occur before a mailbox consumer runs.

### Event catalog and envelopes

`Ircxd.Client.Event.names/0` is the canonical public event-name catalog.
`Ircxd.Client.Event.spec/1` identifies terminal and derivative events, allowing
consumer contract tests to require an explicit disposition after an ircxd
upgrade:

```elixir
assert MapSet.subset?(
         MapSet.new(Ircxd.Client.Event.names()),
         MapSet.new(MyApp.IrcEventDisposition.names())
       )
```

Both `:ack` and `:labeled_response` are terminal because each represents an
unambiguous logical response boundary. `:labeled_response` is also derivative:
consumers can use it for correlation without treating it as another content
row.

Atom and tuple events remain the default. Start a client with
`events: :envelope` to receive one `%Ircxd.Client.Event{}` for each published
event, or `events: :both` during migration. An envelope provides `:name`,
`:payload`, `:message`, `:label`, `:batch`, server-time and duplicate metadata,
`:origin`, `:terminal?`, and `:derivative?`; `:legacy` retains the original
event exactly. Envelope mode replaces rather than duplicates the legacy
publication.

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

For `/quote`-style text, parse the line before sending it:

```elixir
with {:ok, message} <- Ircxd.ClientCommand.parse("TOPIC #elixir :A new topic"),
     :ok <- Ircxd.Client.transmit(client, message) do
  :sent
end
```

The parser preserves trailing parameters, including an empty trailing value,
normalizes the command name, and enforces parameter, injection, and wire-size
limits. It rejects source prefixes, numeric replies, and tags by default. A
trusted caller can enable grammar features explicitly:

```elixir
Ircxd.ClientCommand.parse("@label=req-1 WHOIS alice", tags: :allow)
```

Tag opt-in performs structural validation only. Sending the parsed message
still applies the live client's capability and transport-security checks.
Product permissions—such as whether a browser user may issue `OPER`—remain the
host application's responsibility.

`Ircxd.CommandSpec` publishes the reusable protocol portion of command
metadata:

```elixir
spec = Ircxd.CommandSpec.classify("MODE", ["#room", "+b"], info)
# => %{family: :query, result_events: [:ban_list], terminal_events: [:ban_list_end], ...}
```

Known specs include command syntax, family, required capabilities, relevant
ISUPPORT tokens, sensitive parameter positions, result/terminal event hints,
partial success, and client-state effects. Unknown vendor commands remain
representable with `known?: false`; that result is not a safety or permission
decision.
Argument-aware MODE classification uses the supplied snapshot's CHANTYPES,
CHANMODES, and PREFIX values. Command completion metadata is a correlation hint,
not a delivery guarantee.

`Ircxd.Client.quit/2` and a raw or transmitted `QUIT` are intentional
disconnects. After the server closes the transport, the client emits
`:disconnected` followed by
`{:disconnect, %{reason: :quit, intentional?: true, reconnecting?: false}}`.
The client process stays alive but disconnected, so a permanent OTP supervisor
does not immediately start a replacement connection. Call
`Ircxd.Client.reconnect/1` to connect that process again explicitly.

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
helper such as `Ircxd.Client.chathistory_latest/4` returns an error if its
required capability is not active.

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

Transport errors and unintentional closes use the configured reconnect policy.
An intentional `QUIT` suppresses that policy for its close. Pending labeled
requests receive a final `:failed` lifecycle event before connection-specific
state is cleared.

When a bounded reconnect policy uses its last attempt, the client emits
`{:reconnect_exhausted, %{attempts: count, max_attempts: limit, reason: reason}}`
and stops normally. The default client child specification is `:transient`, so
a supervisor does not defeat that bound by restarting the normal exhaustion
exit. An unexpected abnormal exit, including an initial connection failure,
is still restartable by a supervisor. A normal unintentional disconnect with
reconnection disabled is likewise not restarted automatically.

An initial connection failure emits `{:connect_error, reason}` and stops the
client abnormally. Use an OTP supervisor to restart failures that occur before
a transport has been established.

## Implementing an adapter

`Ircxd.Client.Adapter` is the application integration boundary for a client
connection. It receives the same normalized events exposed through `:notify`,
with stateful callback handling for persistence, application broadcasts,
metrics, bot behavior, or other side effects.

Client and server integrations use parallel names and configuration:

| Component | Behavior | Option | Primary event callback |
| --- | --- | --- | --- |
| IRC client | `Ircxd.Client.Adapter` | `adapter: {Module, init_arg}` | `c:Ircxd.Client.Adapter.handle_event/3` |
| IRC server | `Ircxd.Server.Adapter` | `adapter: {Module, init_arg}` | `c:Ircxd.Server.Adapter.handle_event/3` |

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
| `c:Ircxd.Client.Adapter.init/1` | Initialize application callback state. | `{:ok, state}` or `{:error, reason}` |
| `c:Ircxd.Client.Adapter.handle_event/3` | Consume one normalized client event. | `{:ok, state}` |

The event context contains:

| Key | Meaning |
| --- | --- |
| `:client` | The client process PID. |
| `:host` | Configured remote host. |
| `:port` | Configured remote port. |
| `:tls?` | Whether the connection uses implicit TLS. |
| `:nick` | The client's current nickname at event time. |
| `:client_info` | Secret-free cached protocol snapshot at event time. |

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

The client invokes `c:Ircxd.Client.Adapter.handle_event/3` synchronously in its
GenServer, in protocol order. Updated callback state is used for the next
event. Keep the callback fast. A slow database call also delays socket
processing and can increase mailbox size. For slow or retryable work, enqueue
a compact event to an application-supervised worker or durable outbox.

An invalid callback return retains the previous state. Adapter initialization
failure stops client startup as `{:adapter_init_failed, reason}`. Do not use the
callback state as the only copy of durable data; it ends with the client
process.
