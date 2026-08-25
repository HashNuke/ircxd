# Client integration usage feedback

## Implementation progress

Implementation started on 2026-08-25. This section is updated at each tested
checkpoint; the detailed acceptance lists below remain the source of truth.

- [x] Checkpoint 1 — Event metadata consistency and labeled-response semantics
- [x] Checkpoint 2 — Nickname and intentional disconnect lifecycle
- [x] Checkpoint 3 — Client-command parsing and shared outbound safety
- [x] Checkpoint 4 — Cached state and casemapping-aware identity
- [x] Checkpoint 5 — Event catalog, optional event envelopes, and command specs
- [x] Independent Sol xhigh review reports no remaining issues
- [x] Full validation passes and the implementation is committed

Progress notes:

- 2026-08-25: implementation and focused TDD pass started for checkpoint 1.
- 2026-08-25: checkpoint 1 focused tests pass. NAMES, WHO, WHOX, and nickname
  errors use the common metadata pipeline; structured events retain raw,
  label, and batch metadata; ACK-only requests complete; invalid ACK-plus-batch
  fixtures were split; and labeled-response now requires `batch`.
- 2026-08-25: checkpoint 2 focused tests pass. Registration-only nickname
  fallback is preserved, post-registration 433 retains the confirmed nick,
  001 establishes the confirmed nick, intentional QUIT suppresses reconnect,
  explicit reconnect is supported, transport errors use reconnect policy, and
  pending labeled requests fail predictably on disconnect.
- 2026-08-25: checkpoint 3 focused tests pass. `Ircxd.ClientCommand` provides a
  process-free parser with explicit source, numeric, and tag policies; shared
  outbound validation normalizes command case before security checks and
  rejects NUL, source prefixes, invalid tags, invalid labels, parameter-count
  overflow, and wire-size overflow.
- 2026-08-25: checkpoint 4 focused tests pass. A typed secret-free connection
  snapshot is available externally and in adapter context, updates across CAP,
  ISUPPORT, registration, NICK, and reconnect state, and normalized identity
  events carry casemapping-aware source/target self flags captured at event
  processing time.
- 2026-08-25: checkpoint 5 focused tests pass. The canonical event catalog is
  enforced at the publication boundary, adapters have useful event types,
  opt-in envelope and dual migration modes are available, and command specs
  cover the complete focused helper surface with capability, sensitivity,
  result, terminal, and argument-aware MODE/TOPIC metadata.
- 2026-08-25: the complete verification gate passes: formatting,
  warnings-as-errors compilation, 453 default tests, generated documentation,
  package contents, one standard-replies integration test, and two
  services-backed IRCv3 integration tests.
- 2026-08-25: independent Sol/xhigh review round 1 found 11 issues. Remediation
  covered stale reconnect messages/timers, existing and nested labeled batch
  types, server-side labeled WHOIS framing, total outbound validation, retry
  failures, confirmed nick state, remaining event-pipeline bypasses, command
  metadata, envelope metadata, and identity coverage. The 29-test focused
  remediation suite passes. A broader client/server test pass exposed two
  stale test assumptions around pre-001 identity and CAP negotiation ordering;
  their corrected contracts pass across six repeated focused runs. The full
  verification gate then passed with 460 default tests, generated docs,
  package validation, one standard-replies integration test, and two
  services-backed integration tests. Independent Sol/xhigh review round 2 then
  found seven additional issues: malformed client-batch validation, remaining
  SASL/STS pipeline bypasses, zero-argument labeled WHOIS, stale server-time
  timers, command-spec omissions, reconnect-exhaustion lifecycle semantics,
  and derivative identity flags. All seven were accepted; the 33-test focused
  remediation suite now passes. The timing, supervision, and batch tests also
  pass across five consecutive randomized runs, and the 70-test impacted suite
  is green. The post-remediation full gate then passed with 464 default tests,
  generated docs, package validation, one standard-replies integration test,
  and two services-backed integration tests. Review round 3 remains pending.
- 2026-08-25: independent Sol/xhigh review round 3 found five additional
  edge cases: STS double correlation on labeled CAP replies, raw server-time
  tags ignored by some structured events, incomplete TAGMSG derivative
  metadata, invalid client-batch header grammar, and TAGMSG capability bypass
  with empty/unprefixed tags. All five were accepted; the 20-test focused
  remediation suite now passes. Broader validation and review round 4 remain
  pending. The 80-test impacted suite is green, and the 20-test regression
  group passes across four consecutive randomized runs. The post-remediation
  full gate then passed with 467 default tests, generated docs, package
  validation, one standard-replies integration test, and two services-backed
  integration tests. Review round 4 remains pending.
- 2026-08-25: independent Sol/xhigh review round 4 found two additional valid
  interaction issues: server-time publication buffering also deferred batch
  bookkeeping past an untimed batch close, and the event catalog did not mark
  ACK and completed labeled responses as terminal. Both reproductions failed
  before the implementation change and now pass. Batch and aggregate state is
  collected on arrival, buffered publication retains the original batch
  context, and both logical completion events are terminal. The 7-test focused
  suite passed across four randomized runs, the 25-test impacted suite is
  green, and the complete gate passed with 469 default tests, generated docs,
  package validation, one standard-replies integration test, and two
  services-backed integration tests. Review round 5 found one remaining direct
  response lifecycle case: timestamped single replies and ACKs updated labeled
  request state only on publication, so a prior disconnect incorrectly marked
  an already-observed response failed. The lifecycle now advances on arrival
  while correlated content remains buffered, and flush does not repeat the
  transition. The 13-test focused group passes, its 12 timing-sensitive tests
  pass across four randomized runs, the 35-test impacted suite is green, and
  the complete gate passed with 472 default tests, generated docs, package
  validation, one standard-replies integration test, and two services-backed
  integration tests. Review round 6 found that labeled request lifecycle still
  treated correlated standard `FAIL`, error numerics, and specialized
  rejections as completed rather than failed—an explicit original acceptance
  item. Response finalization now classifies normalized failures for direct
  and batched replies and retains the failure event in `:reason`. The 21-test
  focused suite, 42-test impacted suite, and 15 timing/real-server tests across
  four randomized runs are green. After one unrelated subscriber teardown
  race passed alone at the same seed, a complete repeat gate passed with 475
  default tests, generated docs, package validation, one standard-replies
  integration test, and two services-backed integration tests. Review round 7
  found a contained pre-existing RFC numeric mismatch: successful empty USERS
  numeric 395 was labeled `users_disabled`, while actual disabled error 446
  remained generic, making both the event catalog and USERS command spec
  inaccurate. Numeric 395 now emits non-terminal `users_empty`; 446 emits
  terminal `users_disabled` and fails labeled requests; USERS metadata includes
  the empty result. The 10-test focused group passes across four randomized
  runs, the 36-test impacted suite is green, and the complete gate passed with
  476 default tests, generated docs, package validation, one standard-replies
  integration test, and two services-backed integration tests. Review round 8
  reported no remaining correctness issues.

## Purpose

This document records feedback from integrating `Ircxd.Client` into
topics.club, a persistent web IRC client. It describes the library behavior
the application can use successfully today, the integration gaps uncovered by
raw-command support, and the contracts expected from ircxd rather than from a
host application.

The main use case is not an IRC bot that can react to events transiently. It is
a supervised, multi-user application that must keep four views consistent:

1. The remote IRC server's confirmed state.
2. ircxd's connection, capability, identity, and request state.
3. Durable application state such as channel buffers, history, and auto-join
   preferences.
4. Browser state and command output shown to the user.

For example, when a user submits `/quote JOIN #elixir`, successfully writing a
`JOIN` line is only the start of the operation. The application must wait for
the server's self `JOIN` event before it creates or activates a confirmed
channel membership. If the server instead returns `ERR_INVITEONLYCHAN`, the
application must show a failure and must not leave behind a phantom joined
buffer.

This feedback is intentionally split along the library boundary: ircxd should
own IRC grammar, protocol state, normalized events, and correlation metadata.
The host application should own product permissions, database records, buffer
lifecycle, persistence, and UI presentation.

## What already works well

The current client provides a strong foundation for this integration:

- Focused helpers cover a broad IRC and IRCv3 command surface.
- Incoming lines are normalized into useful structured events.
- `Ircxd.Message` preserves raw protocol data for extensions without a typed
  event.
- Outbound validation covers command shape, parameter count, line size,
  injection characters, UTF-8 policy, sensitive cleartext commands, tags, and
  required capabilities.
- The client retains IRCv3 capabilities, ISUPPORT, current nickname, batches,
  labeled requests, and reconnect state internally.
- Many multiline queries already have explicit terminal events such as
  `who_end`, `whois_end`, `whowas_end`, `names_end`, `list_end`, `help_end`,
  `info_end`, `stats_end`, and `links_end`.
- The documentation correctly says that a successful command call means the
  line was validated and written, not accepted by the server.

The requests below are mostly about making those existing facilities uniform
and consumable without reconstructing protocol state in every host
application.

## Responsibility boundary

### Expected from ircxd

- Parse and serialize IRC correctly.
- Distinguish client commands from server messages.
- Own connection registration, capabilities, SASL, keepalive, batches, and
  reconnect mechanics.
- Keep the confirmed current nickname and advertised server features.
- Emit every message-derived event through one consistent metadata and
  correlation pipeline.
- Preserve labels and batch boundaries on structured replies.
- Describe the event and command surface sufficiently for exhaustive consumer
  handling.
- Expose safe cached protocol state needed to interpret commands.
- Distinguish an intentional quit from an accidental transport loss.

### Expected from the host application

- Decide who may use `/quote` and which command forms are enabled.
- Map an IRC connection to an application user and server record.
- Decide whether a confirmed PART archives or deletes a channel buffer.
- Persist messages, command invocations, results, and application metadata.
- Maintain auto-join preferences and durable channel history.
- Choose whether output belongs in a channel, server, or private-message
  buffer.
- Format results and errors for the UI.
- Apply product-specific secret handling and audit policy.

ircxd should not know about topics.club database schemas or React buffers.
Conversely, topics.club should not have to reparse generic IRC lines or infer
whether ircxd considers a capability active.

## Priority summary

### P0 correctness

- [x] Route all message-derived structured events through the same emission
      pipeline so labels, batches, deduplication, and raw-message metadata are
      never lost.
- [x] Stop automatic nickname fallback for a user-initiated, post-registration
      `NICK` rejection.
- [x] Make an intentional `quit` stop or disconnect the client without
      immediately applying the automatic reconnect policy.
- [x] Define labeled responses as correlation/lifecycle metadata for their
      underlying structured events, without encouraging consumers to render
      the same response twice.

### P1 integration APIs

- [x] Add a client-to-server command-line parser for `/quote`-style input.
- [x] Expose a cached client information snapshot containing registration,
      identity, capabilities, and ISUPPORT state.
- [x] Publish a canonical event catalog and useful event types.
- [x] Provide casemapping-aware self/target identity information or helpers.

### P2 protocol metadata and ergonomics

- [x] Publish reusable command specifications for syntax, command family,
      required capabilities, sensitive parameter positions, result events,
      and terminal events.
- [x] Consider a unified request/event envelope that makes correlation and
      completion state explicit while preserving a backwards-compatible event
      stream during migration.

## Feedback 1 — Use one structured-event emission pipeline

### Current behavior

The client has a common event pipeline that performs message-ID handling,
emits the structured event, derives typing/reaction events, processes labeled
responses, and collects batches:

- [`emit_event_now/3`](../lib/ircxd/client.ex#L1889)

Some incoming numerics bypass that pipeline and call `emit/2` directly. Known
examples include:

- `433` / `nick_in_use`
- `353` / `names`
- `366` / `names_end`
- `352` / `who_reply`
- `354` / `whox_reply`
- `315` / `who_end`

See the direct branches in
[`Ircxd.Client`](../lib/ircxd/client.ex#L837).

### Why this matters

A server can attach a `label` to a single response or wrap a multiline response
in a labeled-response batch. When the structured event bypasses the common
pipeline, the application receives the parsed event and the generic raw
`message`, but it does not receive the same reliable label and batch processing
as events passed through `emit_event/3`.

That makes correlation depend on which numeric happened to implement which
internal emission function rather than on IRC semantics.

### Use case: two overlapping WHO requests

Suppose two browser tabs issue these commands close together:

```text
@label=cmd-101 WHO #elixir
@label=cmd-102 WHO #phoenix
```

The server wraps each sequence of `352` rows and its terminal `315` in a
separate labeled-response batch. The application needs to attach each batch's
rows to the correct command and mark only that command complete. A structured
`who_reply` that bypasses batch collection forces the application to inspect
the duplicate generic `%Ircxd.Message{}` and rebuild correlation manually.

### Use case: NAMES output after JOIN

```text
@label=cmd-201 NAMES #elixir
```

The application wants to use `names` events to update channel presence and
`names_end` to finish the command. If the labeled batch relationship is only
recoverable from generic messages, the consumer either duplicates protocol
parsing or maintains two streams that must be joined and deduplicated.

### Expected behavior

- Every event derived from an incoming `%Ircxd.Message{}` goes through the same
  event pipeline.
- Every structured payload retains the underlying message, either directly or
  through a common envelope.
- Label, batch, duplicate-message-ID, and server-time behavior is consistent
  for all structured events.
- Internal lifecycle events that are not derived from a server message may
  continue to use a simpler emission path.

### Acceptance checklist

- [x] Labeled `WHO`, WHOX, NAMES, and nickname errors preserve their labels.
- [x] Batched versions of those replies participate in batch collection.
- [x] Server-time publication buffering preserves arrival-time batch
      collection, direct labeled-request lifecycle transitions, and captured
      batch context through batch closure.
- [x] Their structured event payloads expose the original message.
- [x] A behavioral contract test identifies message-derived branches that bypass the
      common pipeline.
- [x] Existing unlabeled event shapes remain compatible or have a documented
      migration path.

## Feedback 2 — Make labels metadata, not duplicate content

### Current behavior

The common pipeline first emits the structured event and then emits a second
`labeled_response` event containing that structured event:

[`maybe_emit_labeled_response/3`](../lib/ircxd/client.ex#L2009)

This is useful for request lifecycle tracking, but a consumer can easily
interpret both notifications as displayable result rows and persist the same
reply twice. Labeled batches similarly contain a collection of events that may
already have been observed individually.

### Why this matters

The IRCv3 label identifies one logical response. It does not introduce a
second semantic server reply. Applications should not need undocumented
knowledge that one event is content and the other is only correlation
metadata.

### Use case: WHOIS transcript duplication

For a labeled WHOIS, an application may receive:

```elixir
{:whois_user, details}
{:labeled_response, %{label: "cmd-301", event: {:whois_user, details}}}
```

If both are passed into a generic persistence pipeline, the same WHOIS row is
stored twice. The correct result is one row carrying `command_id: "cmd-301"`.

### Expected behavior

One of these designs would satisfy the integration need:

1. Add correlation metadata directly to a normalized event envelope:

   ```elixir
   %Ircxd.Client.Event{
     name: :whois_user,
     payload: details,
     message: message,
     label: "cmd-301",
     batch: nil
   }
   ```

2. Keep the current structured event and `labeled_response` lifecycle event,
   but document and type the latter explicitly as non-content metadata, with a
   stable identity that lets consumers merge rather than append it.

The first design is easier for new consumers. The second may be useful for
backwards compatibility. They could coexist behind an opt-in event mode during
migration.

### Required semantics

- A single-response label correlates the underlying structured event.
- A labeled `ACK` means the server accepted a command that normally produces
  no response; it is not a second content row.
- A labeled batch is one logical response boundary around its member events.
- Missing, incomplete, or late labeled responses remain possible; the library
  must not promise stronger delivery semantics than IRC provides.
- `PRIVMSG` or `NOTICE` acknowledgment does not prove a human recipient read or
  received the message.

### Acceptance checklist

- [x] Documentation identifies which event carries content and which event
      carries request lifecycle metadata.
- [x] A normal consumer example persists a labeled structured reply exactly
      once.
- [x] Single, ACK, and batched labeled responses have distinct typed lifecycle
      outcomes.
- [x] Labels are treated as opaque values and remain attached through terminal
      events.

## Feedback 3 — Limit nickname retry to registration

### Current behavior

Every `433` nickname-in-use response calls `nick_retry_fun`, sends another
`NICK`, and updates `current_nick`:

[`Ircxd.Client` 433 handling](../lib/ircxd/client.ex#L837)

The client already tracks `registered?`, so it can distinguish an initial
registration collision from a later user-requested nickname change.

### Why this matters

Automatic fallback is useful while connecting because the client cannot finish
registration without an available nickname. After registration, it violates
the semantics expected by an interactive client: rejection of a requested
nickname should preserve the existing nickname and let the user choose what to
do next.

### Use case

The confirmed nickname is `mira` and the user submits:

```text
NICK alice
```

If `alice` is in use, the expected outcome is:

```elixir
{:nick_rejected,
 %{attempted: "alice", code: "433", reason: "Nickname is already in use"}}
```

The confirmed nickname remains `mira`. The current behavior can instead send
`NICK alice_` and make the application explain a nickname the user never
requested.

### Expected behavior

- Before registration, retain configurable automatic nickname retry.
- After registration, do not call the retry function or send a fallback
  nickname automatically.
- Do not modify `current_nick` until a self-authored `NICK` event confirms the
  change.
- Emit a structured rejection containing the numeric, attempted nickname,
  reason, original message, and correlation metadata.
- Ensure the rejection passes through the common event pipeline.

### Acceptance checklist

- [x] Registration-time `433` still invokes the configured retry function.
- [x] Post-registration `433` sends no additional `NICK`.
- [x] Post-registration `433` leaves `current_nick` unchanged.
- [x] A labeled post-registration rejection retains its label.
- [x] Successful self `NICK` and registration welcome remain the only confirmations that change the
      current nickname.

## Feedback 4 — Add a client-command parser

### Current behavior

`Ircxd.Message.parse/1` is a general IRC message parser. It correctly accepts
the modern message shape, including tags, a source prefix, alphabetic
commands, and three-digit numeric replies:

[`Ircxd.Message.parse/1`](../lib/ircxd/message.ex#L26)

That is the right contract for server input, but `/quote` needs a stricter
client-to-server command contract.

### Why this belongs in ircxd

Trailing parameters, empty parameters, line limits, tag limits, and valid
command forms are IRC wire concerns. If each client application implements its
own whitespace splitting and validation, valid messages will be changed and
unsafe forms may reach the transport.

### Use cases

These inputs must produce different typed parameter lists:

```text
TOPIC #room
TOPIC #room :
TOPIC #room :A topic with spaces
PART #room :good night
PRIVMSG Nick :hello there
```

Expected parameters:

```elixir
%{command: "TOPIC", params: ["#room"]}
%{command: "TOPIC", params: ["#room", ""]}
%{command: "TOPIC", params: ["#room", "A topic with spaces"]}
%{command: "PART", params: ["#room", "good night"]}
%{command: "PRIVMSG", params: ["Nick", "hello there"]}
```

The following must be rejected by a default client-command parser even though
some are valid shapes for a generic IRC message:

```text
:spoofed.example PRIVMSG #room :hello
318 me alice :End of WHOIS
PRIVMSG #room :one\r\nOPER root secret
```

### Suggested API

The exact name is not important, but the separation is:

```elixir
Ircxd.ClientCommand.parse(line,
  tags: :forbid,
  source: :forbid,
  numerics: :forbid
)
```

It could return `%Ircxd.Message{}` or a dedicated
`%Ircxd.ClientCommand{command: ..., params: ..., tags: ...}` struct.

### Expected validation

- Preserve a trailing parameter as one value, including the empty string.
- Normalize command names without rewriting parameter values.
- Enforce the 15-parameter and outbound wire-size limits.
- Reject embedded `NUL`, `CR`, and `LF` before serialization.
- Reject source prefixes and numeric commands by default.
- Forbid tags by default, with an explicit option for validated client tags.
- When tags are enabled, reuse ircxd's tag validation and capability rules.
- Return stable, documented error atoms suitable for application error
  messages.

Command-specific product permission does not belong in this parser. Parsing a
valid `OPER` command and allowing a web user to send it are separate decisions.
The shared outbound validator should also reject `NUL` for typed helpers and
direct `%Ircxd.Message{}` transmission, not only for strings that came through
the proposed command-line parser.

### Acceptance checklist

- [x] Round-trip tests cover trailing, empty trailing, and maximum parameter
      forms.
- [x] Injection and over-limit inputs are rejected.
- [x] Prefixes, numerics, and tags follow explicit options rather than
      accidental parser behavior.
- [x] The parser can be used without starting an IRC connection.
- [x] Documentation includes `/quote`-style examples.

## Feedback 5 — Expose cached client protocol state

### Current behavior

The client stores the information needed by consumers internally:

- `available_caps`
- `active_caps`
- `isupport`
- `current_nick`
- `registered?`
- transport and TLS state

See the client state initialized in
[`Ircxd.Client.init/1`](../lib/ircxd/client.ex#L392).

There are APIs that send `CAP LIST` or `ISUPPORT` commands, but no public
getter for the already-cached state. Sending another server query is different
from inspecting the state ircxd is currently using.

### Why this matters

An application needs the same negotiated facts as ircxd when it interprets a
command:

- `CHANTYPES` determines whether `&local` is a channel target.
- `CASEMAPPING` determines whether two nicknames or channels are equal.
- `CHANMODES` and `PREFIX` determine whether a MODE argument is a query or a
  mutation and which parameters it consumes.
- `TARGMAX`, `MAXTARGETS`, `CHANLIMIT`, and `MODES` constrain target expansion.
- Active capabilities determine whether labeled response, CHATHISTORY,
  METADATA, MARKREAD, RENAME, tags, or other extensions may be used.
- The confirmed current nickname is necessary to identify self JOIN, PART,
  NICK, KICK, and MODE events.

### Use case: argument-aware MODE

```text
MODE #room +b
```

On common networks this is a ban-list query because mode `b` is a list mode and
no mask was supplied. In contrast:

```text
MODE #room +b *!*@example.test
```

is a mutation. The host should consult the exact ISUPPORT state parsed by
ircxd rather than hardcoding one network's mode rules.

### Suggested API

```elixir
Ircxd.Client.connection_info(client)
# => %Ircxd.Client.Info{
#   status: :registered,
#   connected?: true,
#   registered?: true,
#   current_nick: "mira",
#   tls?: true,
#   available_caps: %{"labeled-response" => true},
#   active_caps: MapSet.new(["batch", "labeled-response"]),
#   isupport: %{"CASEMAPPING" => "rfc1459", "CHANTYPES" => "#&", ...}
# }
```

The result should be a read of cached process state. It should not cause IRC
traffic.

### Acceptance checklist

- [x] The snapshot changes after registration, `005`, CAP ACK/NAK/NEW/DEL, and
      a confirmed self NICK.
- [x] Reconnect resets stale server-specific features until the new server
      registration repopulates them.
- [x] Secrets such as PASS, SASL credentials, OPER passwords, and WEBIRC
      passwords are never included.
- [x] The shape and consistency guarantees are documented.

## Feedback 6 — Make self identity casemapping-aware

### Current behavior

Structured events expose nicks and targets, while the consumer usually decides
whether an event concerns the current client. ircxd already owns the confirmed
current nickname and parsed ISUPPORT state, and it provides casemapping
helpers.

### Why this matters

ASCII equality is not sufficient on IRC. Depending on `CASEMAPPING`, spelling
variants can identify the same nickname. A host that compares an event against
the nickname stored in its database can also become stale immediately after a
nick change.

### Use cases

- A self `JOIN` must create/activate the local channel membership before the
  application records topic or NAMES output.
- A self `PART` must deactivate the membership; another user's PART only
  updates presence.
- `KICK #room CurrentNick` is a membership change even though the event source
  is the operator who issued the kick.
- A self `NICK` event must update the application's persisted connection
  nickname.

### Expected behavior

Either of these contracts would work:

1. Add normalized identity flags to relevant event payloads:

   ```elixir
   {:join, %{nick: "Mira", channel: "#room", self?: true}}
   {:kick, %{target_nick: "Mira", target_self?: true, channel: "#room"}}
   ```

2. Expose a public helper using the client's current state:

   ```elixir
   Ircxd.Client.self_nick?(client, nick)
   Ircxd.Client.same_identifier?(client, left, right)
   ```

Flags are preferable for asynchronous consumers because they describe the
identity at the moment ircxd processed the event, even if another nick change
has occurred before the consumer handles its mailbox.

### Acceptance checklist

- [x] JOIN, PART, NICK, QUIT, KICK, MODE, TOPIC, and message events have a
      documented self-identification story.
- [x] Comparisons use negotiated CASEMAPPING with the appropriate fallback.
- [x] A successful self NICK updates identity before subsequent events are
      classified.
- [x] Tests cover case variants and a rapid NICK followed by another event.

## Feedback 7 — Distinguish intentional quit from reconnectable loss

### Current behavior

`Ircxd.Client.quit/2` sends a `QUIT` line through the ordinary send path:

[`Ircxd.Client.quit/2`](../lib/ircxd/client.ex#L165)

When the socket closes, `handle_disconnect/1` applies the configured reconnect
policy without knowing that the client requested the close:

[`handle_disconnect/1`](../lib/ircxd/client.ex#L668)

### Why this matters

Automatic reconnect is correct for a network interruption. It is surprising
for an explicit user command such as `/quit` or `/quote QUIT :done`, which is a
request to end the IRC session.

### Use case

The client is configured with `reconnect: true` and the user sends:

```text
QUIT :Signing off
```

Expected lifecycle:

1. ircxd writes QUIT.
2. The server may send `ERROR` and closes the transport.
3. ircxd emits an intentional-disconnect lifecycle event and terminates
   normally, or remains stopped without scheduling reconnect.

The client should not reconnect one second later and silently rejoin all
channels.

### Suggested API

One possible API is:

```elixir
Ircxd.Client.quit(client, "Signing off", reconnect: false)
```

Another is to define `quit/2` as an intentional terminal operation and add a
separate low-level `send_quit/2` if a caller truly wants the configured
reconnect policy afterward.

### Expected behavior

- Intentional quit suppresses automatic reconnect for that disconnect.
- Network loss and protocol errors continue to use the configured reconnect
  policy.
- The lifecycle event indicates whether a disconnect was intentional,
  reconnecting, exhausted, or caused by an error.
- Pending labeled requests are completed/failed or cleared predictably.
- The API documents whether the client process stops and what a supervisor will
  do with its exit reason.

### Acceptance checklist

- [x] `quit` with reconnect configured does not reconnect unless explicitly
      requested.
- [x] A later network loss still reconnects.
- [x] Intentional quit emits a distinguishable lifecycle reason.
- [x] Supervised-client behavior is documented and tested.

## Feedback 8 — Publish a canonical event catalog and types

### Current behavior

The client adapter defines its event type as `term()`:

[`Ircxd.Client.Adapter`](../lib/ircxd/client/adapter.ex#L11)

The actual event surface is large and useful, but consumers discover it by
reading `Ircxd.Client` clauses and tests. There is no machine-readable way to
verify that an application has intentionally handled or ignored every event.

### Why this matters

topics.club needs an event-disposition inventory. Each ircxd event should be
classified as one or more of:

- Display to the user.
- Persist in history.
- Update application state.
- Correlate a pending command.
- Treat as internal lifecycle metadata.
- Intentionally ignore for a documented reason.

When an ircxd upgrade introduces an event, a contract test should fail until
the application chooses a disposition. Otherwise the existing catch-all can
silently discard new command output.

### Expected behavior

At minimum, provide a canonical event-name list:

```elixir
Ircxd.Client.Event.names()
```

A stronger contract would define an event struct and types:

```elixir
@type name :: :join | :part | :who_reply | :who_end | ...

defstruct [
  :name,
  :payload,
  :message,
  :label,
  :batch,
  :server_time,
  :duplicate_msgid?
]
```

Event metadata could identify whether an event is message-derived, terminal,
internal, or an additional semantic view of another event. It should not
classify application behavior such as “persist this,” because that remains a
consumer decision.

### Use case

```elixir
assert MapSet.subset?(
         MapSet.new(Ircxd.Client.Event.names()),
         MapSet.new(Ircpipe.Irc.EventDisposition.names())
       )
```

After upgrading ircxd, this test identifies an unreviewed event instead of
letting it disappear through `handle_info({:ircxd, _event}, state)`.

### Acceptance checklist

- [x] Every public notify/adapter event is documented and represented in the
      catalog.
- [x] Semantic derivative events such as typing, reaction, duplicate message,
      generic message, and labeled lifecycle events are clearly identified.
- [x] ACK and completed labeled responses are marked as terminal logical
      response boundaries.
- [x] Adding or removing a public event requires updating a library contract
      test.
- [x] Adapter types are more informative than `term()`.

## Feedback 9 — Publish protocol command specifications

### Scope

This is lower priority than uniform events and parsing, but it would prevent
IRC protocol facts from being duplicated across interactive clients.

A complete topics.club command registry contains both protocol facts and
product policy. Only the protocol portion belongs in ircxd.

### Expected library-owned metadata

For known client commands, a specification could provide:

- Valid parameter shapes and target-list behavior.
- Broad family such as query, state mutation, messaging, registration,
  protocol-owned, operator, or extension.
- Required active capability or relevant ISUPPORT token.
- Sensitive parameter positions, such as PASS, OPER password, JOIN keys, MODE
  channel keys, REGISTER password, and VERIFY code.
- Structured result events.
- Terminal events or single-response semantics.
- Whether a command can partially succeed per target.
- Whether the command affects client protocol state managed by ircxd.

It should not decide which topics.club users may execute the command, where a
result is displayed, or how a database row changes.

### Use cases

#### MODE query versus mutation

```text
MODE #room
MODE #room +b
MODE #room +b *!*@example.test
MODE #room +o Alice
```

The first is a channel-mode query. With common ISUPPORT, the second is a
ban-list query. The latter two are mutations. A reusable classifier must use
the negotiated `CHANMODES` and `PREFIX` values.

#### Multi-target JOIN

```text
JOIN #public,#staff ,staff-key
```

The server can accept one channel and reject the other. The key association is
protocol syntax and the key is sensitive. The decision to create a durable
buffer after each confirmed self JOIN belongs to the application.

#### Query completion

```text
WHOIS Alice
```

The result may contain many WHOIS events and completes at `whois_end` (`318`)
or a correlated terminal failure. That mapping is reusable protocol metadata.

### Suggested split

```elixir
# Library protocol facts
Ircxd.CommandSpec.classify("MODE", ["#room", "+b"], client_info)
# => %{family: :query, result_events: [...], terminal_events: [:ban_list_end]}

# Application product policy
Ircpipe.Irc.CommandRegistry.resolve(command_spec, current_user, buffer)
# => %{enabled?: true, destination: ..., reconciler: ...}
```

### Acceptance checklist

- [x] The specification covers all commands for which `Ircxd.Client` exposes a
      focused helper.
- [x] Unknown/vendor commands remain representable without being declared safe.
- [x] MODE and TOPIC classification is argument-aware.
- [x] Terminal mappings agree with the events ircxd actually emits.
- [x] Sensitive metadata never includes the sensitive value itself.

## Expected request and completion semantics

The integration expects these states to remain distinct:

1. `parsed` — the command line is syntactically valid.
2. `accepted locally` — policy and capability validation passed.
3. `sent` — the line was written to the IRC transport.
4. `acknowledged` — a server label ACK or defined response was observed.
5. `completed` — the command's terminal event or logical response boundary was
   observed.
6. `failed` — a correlated numeric, standard `FAIL`, or transport condition
   rejected the operation.
7. `timed out` — no terminal condition arrived within the consumer's policy.

ircxd already documents the distinction between send success and server
acceptance. A unified event/request contract should preserve it.

Implemented labeled-request lifecycle events preserve that distinction:
successful logical boundaries use `status: :completed`, while correlated IRC
error/rejection events and standard `FAIL` replies use `status: :failed` with
the normalized failure event in `:reason`. The same classification applies to
direct replies and labeled-response batches.

### Examples

#### Stateful command

```text
JOIN #private
```

- `:ok` from `join/2`: sent.
- Self `join` event: confirmed success and application reconciliation point.
- `473`: failed; do not create a confirmed membership.

#### Query command

```text
WHO #elixir
```

- `:ok` from `who/3`: sent.
- Zero or more `who_reply`/`whox_reply` events: content.
- `who_end`: completed.

#### Message command

```text
PRIVMSG Alice :hello
```

- `:ok` from `privmsg/3`: sent.
- Labeled ACK: accepted by the server.
- Echoed PRIVMSG: useful for canonical display/deduplication when negotiated.
- None of these proves Alice read the message.

## Compatibility expectations

The current event tuples are already useful and may have external consumers.
The improvements above do not require an abrupt breaking change.

Possible migration strategy:

1. Fix events that accidentally bypass correlation while retaining their
   tuple names.
2. Add missing `message`, label, and self-identification fields to payload
   maps where that is backwards-compatible.
3. Add `ClientCommand.parse/2`, `Client.connection_info/1`, and the event
   catalog as new APIs.
4. Introduce an opt-in normalized event envelope, for example
   `events: :envelope`, while keeping legacy tuples temporarily.
5. Deprecate ambiguous duplicate-content interpretations in documentation
   before changing defaults in a major release.

The low-level `raw/3`, `raw_tagged/4`, and `transmit/2` escape hatches should
remain available. A general IRC library should permit vendor commands. The
host application remains responsible for deciding whether unclassified raw
commands are appropriate for its users.

## Suggested implementation checkpoints

ircxd's repository uses test-driven checkpoints. The following order keeps
each change independently useful:

### Checkpoint 1 — Event metadata consistency

- [x] Add failing labeled WHO, WHOX, NAMES, and `433` tests.
- [x] Route primary normalized message-derived events through the common pipeline.
- [x] Ensure the original message is present in normalized payloads.
- [x] Document content versus labeled lifecycle events.
- [x] Run focused client tests; full-suite validation is tracked at completion.

### Checkpoint 2 — Nick and quit lifecycle correctness

- [x] Add registration and post-registration `433` tests.
- [x] Gate nickname retry on registration state.
- [x] Add intentional quit with reconnect-enabled tests.
- [x] Implement and document intentional disconnect semantics.
- [x] Run focused reconnect/nickname tests; full-suite validation is tracked at completion.

### Checkpoint 3 — Client command parsing

- [x] Add parser tests for trailing parameters, empty values, limits, tags,
      prefixes, numerics, and injection characters.
- [x] Add the public parser and stable errors.
- [x] Document `/quote`-style usage.
- [x] Run message/parser tests; full-suite validation is tracked at completion.

### Checkpoint 4 — Cached state and identity

- [x] Add snapshot tests across registration, ISUPPORT, CAP changes, NICK, and
      reconnect.
- [x] Add a secret-free cached state API.
- [x] Add casemapping-aware self flags and helpers.
- [x] Run focused client lifecycle tests; full-suite validation is tracked at completion.

### Checkpoint 5 — Catalog and optional command specs

- [x] Inventory the complete public event surface.
- [x] Add event types/catalog and a coverage test.
- [x] Add command specifications incrementally, beginning with query terminal
      events and MODE/TOPIC classification.
- [x] Update client adapter documentation and generated API docs.
- [x] Run documentation, type, package, and full project checks.

## Definition of done for the topics.club integration

From the consumer's perspective, the library portion is complete when:

- [x] `/quote` input can use an ircxd-owned client-command parser without
      reimplementing IRC parameter grammar.
- [x] Every structured server reply consistently carries or can be merged with
      its label, batch, raw message, and terminal metadata.
- [x] A labeled structured reply has one obvious content representation and
      cannot be mistaken for two server results in the documented usage path.
- [x] User-requested post-registration NICK rejection never triggers an
      unrequested fallback nickname.
- [x] Intentional QUIT does not reconnect unless the caller asks it to.
- [x] Consumers can inspect current nick, registration, capabilities, and
      ISUPPORT without sending a server query.
- [x] Self membership events can be identified using the same casemapping and
      current identity as ircxd.
- [x] The complete public event surface is documented and testable as a
      catalog.
- [x] Query terminal events and standard failures remain stable enough for a
      consumer to implement accurate completed/failed/timed-out states.
- [x] The library makes no assumptions about application persistence, buffer
      retention, permissions, or UI presentation.
