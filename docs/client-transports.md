# Client transports

Every `Ircxd.Client` uses an `Ircxd.Client.Transport` adapter. The default
`Ircxd.Client.Transport.Socket` adapter contains Ircxd's existing TCP/TLS connection behavior, so
existing callers need no code or configuration changes. `Ircxd.Client.Info.transport` continues to
report `:gen_tcp` or `:ssl` for the default adapter.

Set `:transport_adapter` only when another process or service must own the connection while Ircxd
continues to own IRC parsing, protocol state, validation, commands, and events:

```elixir
Ircxd.Client.start_link(
  host: "irc.example.net",
  port: 6697,
  tls: true,
  nick: "example",
  transport_adapter: {MyApp.IrcTransport, connection_id: 42}
)
```

The adapter receives the client PID and credential-free endpoint settings in `connect/3`. Raw TLS
options remain private to Ircxd, and retained checkpoints contain no credentials. However,
`send_data/2` receives complete IRC wire records and therefore sees PASS, WEBIRC, SASL payloads,
and any later command containing sensitive data. Adapters must protect that data in transit and
must not log wire records. The default socket adapter receives TLS options through its private
initialization argument.

## Adapter contract

An adapter implements `Ircxd.Client.Transport`:

```elixir
defmodule MyApp.IrcTransport do
  @behaviour Ircxd.Client.Transport

  @impl true
  def connect(client, config, opts) do
    case MyConnectionOwner.attach(client, config, opts) do
      {:ok, handle} -> {:ok, handle, :fresh}
      {:ok, handle, checkpoint, metadata} ->
        {:ok, handle, {:resumed, checkpoint, metadata}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_data(handle, data), do: MyConnectionOwner.send_data(handle, data)

  # Optional. Implement this only when the owner can suppress a repeated logical write.
  @impl true
  def send_data_once(handle, keys, data) do
    MyConnectionOwner.send_data_once(handle, keys, data)
  end

  @impl true
  def activate(_handle), do: :ok

  @impl true
  def checkpoint?(_handle), do: true

  @impl true
  def accepted(handle, receipt, checkpoint) do
    # This runs in the Ircxd client process after its events have been sent. Relaying a marker to
    # the same event consumer preserves mailbox order with those events.
    send(MyConnectionOwner.consumer(handle), {:irc_record_accepted, handle, receipt, checkpoint})
    :ok
  end

  @impl true
  def handle_info(_message, _handle), do: :unknown

  @impl true
  def close(handle, reason), do: MyConnectionOwner.detach(handle, reason)
end
```

The handle is adapter-owned and must identify one connection attempt. Ircxd ignores data and close
events carrying an earlier handle after reconnect. `close/2` must tolerate repeated calls because
the upstream owner and Ircxd can observe closure concurrently. A cleanup error prevents reconnect;
Ircxd will not open a second handle while the adapter reports that the prior one may remain active.

`activate/1` enables the next inbound record. It is a no-op for an owner that already implements
its own flow control. `handle_info/2` lets an adapter translate process messages it owns; return
`:unknown` for unrelated messages. The default socket adapter uses both callbacks for active-once
TCP/TLS reads.

Set `checkpoint?/1` to `false` when the transport cannot resume. This avoids constructing a parser
checkpoint for each record. A resumable transport returns `true`.

### Optional idempotent writes

`send_data_once/3` is an optional callback for a connection owner that can remember logical writes
for the lifetime of its handle. `Ircxd.Client.join/3` and `Ircxd.Client.transmit/3` accept an
`:idempotency_keys` option. Ircxd requires a non-empty list of non-empty binaries, removes duplicate
keys while preserving their first-seen order, serializes the IRC record once, and passes the keys
and record to `send_data_once/3`.

The adapter owns key retention and overlap policy; Ircxd does not place outbound keys in its parser
checkpoint. A multi-key write should be atomic from the adapter's perspective: write when none of
the keys were recorded, suppress the retry when all were recorded, and return an error on partial
overlap instead of guessing that part of the IRC record was sent. Record keys only after the
underlying write succeeds. If the outcome is uncertain, return an error and do not follow it with
an ordinary write for the same attempt.

If an adapter does not implement `send_data_once/3`, Ircxd deliberately falls back to
`send_data/2`. This keeps existing adapters and the default TCP/TLS socket transport compatible, but
the fallback provides no duplicate suppression. Callers that require the guarantee must select an
adapter that implements the optional callback and defines a bounded key-retention policy.

## Inbound records and acceptance

The adapter or its connection owner delivers one complete IRC record with:

```elixir
Ircxd.Client.Transport.deliver(client, handle, receipt, line)
```

Ircxd parses the line, sends all resulting events, calls `accepted/3` with the post-record parser
checkpoint, and then activates the next read. Parse errors also reach `accepted/3`; a malformed
record is terminally consumed rather than replayed forever.

`accepted/3` means the Ircxd parser accepted the record. It does not by itself mean a separate host
application durably processed the resulting events. A durable transport should use `accepted/3` to
send an ordered marker to the same process receiving Ircxd events. That consumer first handles the
preceding events and then atomically stores `checkpoint` while acknowledging `receipt` upstream.
Do not acknowledge the durable record merely because it was delivered to the Ircxd process.

Before IRC registration completes, `checkpoint` is `nil`. If the client or host crashes in that
state, the owner must discard the retained connection and establish a fresh one. Ircxd instead
passes `{:unavailable, reason}` when registered parser state cannot be safely retained, including an
oversized checkpoint or deferred server-time events. The owner must not acknowledge that record;
close the retained generation and establish a fresh connection.

Report upstream closure with:

```elixir
Ircxd.Client.Transport.closed(client, handle, reason)
```

The existing `:reconnect` option remains authoritative. A reconnect calls the selected adapter's
`connect/3` again.

## Fresh connections

Return `{:ok, handle, :fresh}` for a new, unregistered upstream connection. Ircxd sends its normal
WEBIRC, PASS, CAP, NICK, USER, and optional SASL registration traffic through `send_data/2`.

## Resumed connections

Return `{:ok, handle, {:resumed, checkpoint, metadata}}` only for an upstream connection that is
already registered. Ircxd restores the checkpoint and does not send registration traffic.

The checkpoint is opaque, versioned, integrity-checked, and limited to 65,536 bytes in its
uncompressed Erlang external-term envelope. Retain the exact value received by `accepted/3`; do not
construct or edit it. It contains bounded inbound parser state needed across a restart, including
current nick, negotiated capabilities, ISUPPORT, message-ID deduplication, and in-progress batch,
multiline, metadata, labeled-response, and network-batch state.

Outbound request tracking and generated multiline references remain process-local. Outbound
command parameters can contain credentials, so Ircxd never places them in a checkpoint. Server
passwords, SASL and WebIRC credentials, raw TLS options, callbacks, PIDs, and timer references are
also excluded. Deferred server-time buffers and parser state larger than the checkpoint envelope
make the current connection non-resumable instead of creating a partial checkpoint.

Checkpoints are bound to the connection and parser configuration that created them, including host,
port, TLS mode, SNI, non-secret TLS verification policy, desired nick, username, real name,
requested capabilities, public SASL and WebIRC identity, message-ID mode, and server-time ordering.
Ircxd rejects an unknown version, changed integrity digest, malformed payload, or mismatched
binding.

Set the non-secret `:resume_binding` option to a deployment or credential generation token, and
rotate it when server, SASL, or WebIRC secrets change or when TLS material changes without changing
its configured path. The token itself is hashed into the binding. Ircxd automatically fingerprints
inline CA/certificate material and hostname-verification policy, but deliberately does not retain
private keys or passwords in any form.

After restoration, the client publishes these events in order:

```elixir
{:connected, connection_metadata}
{:resumed, transport_metadata}
:registered
```

The adapter-defined metadata is not protocol state. It may identify the retained connection
generation, replay count, or detached duration.

A replay gap is not safely repairable from an IRC client cache: the missed records could include
nick, capability, ISUPPORT, membership, or batch state changes. If the owner reports a gap, if no
valid registered checkpoint exists, or if Ircxd rejects the checkpoint, close that generation and
establish a fresh IRC connection. Never send registration commands through an already registered
upstream socket.
