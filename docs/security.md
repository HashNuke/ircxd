# Security Review

Review date: 2026-07-29  
Reviewed revision: `fc56dd5` (`server`)

## Executive summary

`ircxd` has a small dependency surface, explicit IRC wire-size validation, no
dynamic code evaluation, and clear host-application boundaries for DCC,
WebSocket transport, and persistence. Those are useful foundations.

The initial review found four high-severity issue groups:

1. The TLS client does not authenticate server certificates by default.
2. SASL `EXTERNAL` on the server is not bound to a client certificate.
3. TCP/TLS input handling allows straightforward memory and connection
   exhaustion.
4. The server advertises IRC casemapping but does not apply it to nicknames,
   channels, bans, or routing.

## Remediation update

SEC-001 through SEC-005 were remediated in the working tree on 2026-07-29:

- TLS clients now verify the certificate chain and hostname by default using
  the system CA store.
- SASL EXTERNAL is disabled by default and can only be enabled on a
  peer-verifying TLS listener; authenticators receive the verified certificate
  and its SHA-256 fingerprint.
- Client and server sockets use active-once flow control and a socket-level
  8,703-byte IRCv3 wire bound. Server command delivery is backpressured, with
  configurable command-rate and connection limits.
- TLS handshakes run in bounded supervised workers with a configurable finite
  timeout.
- The server maintains casemapped nickname and channel indexes and applies the
  same mapping to routing, modes, bans, MONITOR, WHO/WHOIS, history, and
  redaction targets.

The original findings remain below as a record of the threat and remediation
requirements. Their headings now show their current status.

## Scope and method

The review covered the Elixir sources under `lib/`, the Mix dependency lock,
server and client tests, and the documented host boundaries. It focused on:

- TLS and socket lifecycle
- IRC parsing and serialization
- SASL and server-password authentication
- nickname, channel, history, and mode authorization
- callback/process isolation
- attacker-controlled state growth
- credential and secret handling
- dependency advisories and dangerous runtime primitives

The attacker models were an unauthenticated Internet client connecting to
`Ircxd.Server`, a malicious or impersonated IRC server connected to
`Ircxd.Client`, and a normal authenticated IRC user attempting to bypass channel
policy. Application-supplied callback modules and BEAM operators are trusted.

This is a source-level review, not a formal cryptographic audit or an
infrastructure penetration test.

## Findings

### SEC-001 — High — TLS server certificates are not verified by default — Resolved

At the reviewed revision, the client defaulted `tls_options` to an empty list and added only Server Name
Indication before calling `:ssl.connect/4`
([client.ex](../lib/ircxd/client.ex#L385),
[client.ex](../lib/ircxd/client.ex#L592)). Erlang TLS clients default to
`verify_none` because certificate verification also requires trust-store
configuration. SNI selects a virtual host; it does not authenticate it.

An active network attacker can impersonate the IRC server and read or modify
server passwords, SASL credentials, private messages, and all subsequent IRC
traffic. This is especially dangerous because the client supports credential
authentication without requiring an authenticated TLS connection.

Remediation:

- Make `verify: :verify_peer` the client default.
- Load an OS CA bundle or require `:cacerts`/`:cacertfile`.
- Configure hostname verification with
  `customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]`.
- Treat `verify_none` as an explicit, prominently documented development-only
  override.
- Add tests for a trusted certificate, an unknown CA, and a hostname mismatch.

Reference: [Erlang TLS hardening guide](https://www.erlang.org/docs/29/apps/ssl/ssl_hardening.html).

### SEC-002 — High — SASL EXTERNAL accepts an unproven identity — Resolved

At the reviewed revision, when a client selected `EXTERNAL`, the server decoded the client-supplied
authorization identity and passes it to the generic authenticator with an empty
password
([connection.ex](../lib/ircxd/server/connection.ex#L161),
[connection.ex](../lib/ircxd/server/connection.ex#L461)). The connection does
not retrieve a TLS peer certificate, `EXTERNAL` is accepted on plain TCP, and
the authenticator metadata contains neither the SASL mechanism nor certificate
details
([connection.ex](../lib/ircxd/server/connection.ex#L470)).

An authenticator that reasonably interprets an `EXTERNAL` username as a
certificate-authenticated identity can therefore grant an account chosen by an
unauthenticated client. The existing integration test demonstrates acceptance
based only on the submitted identity.

Remediation:

- Disable `EXTERNAL` until certificate-bound authentication is implemented.
- Permit it only on TLS connections with `verify_peer` client-certificate
  validation.
- Obtain the peer certificate with the SSL API and pass a verified certificate
  fingerprint/subject, transport, peer address, and `mechanism: :external` to
  the authenticator.
- Give PLAIN and EXTERNAL separate callbacks or include an unambiguous
  mechanism in a typed authentication request.
- Add negative tests for plain TCP, absent certificates, invalid chains, and an
  authzid that does not match application policy.

### SEC-003 — High — Socket input has no effective flow control or packet bound — Resolved

At the reviewed revision, both the client and each server connection used `packet: :line` with
`active: true`
([client.ex](../lib/ircxd/client.ex#L45),
[connection.ex](../lib/ircxd/server/connection.ex#L39)). Neither side sets
`packet_size`. The parser enforces IRC limits only after the socket has
assembled and delivered a line
([message.ex](../lib/ircxd/message.ex#L25)).

Erlang documents that `active: true` has no flow control and that a fast sender
can overflow the receiver's mailbox. The packet decoder's size limit defaults
to zero, meaning no limit. An attacker can therefore:

- send complete lines faster than a connection process can handle them,
  growing its mailbox;
- send a very long unterminated line, causing buffering before
  `Message.parse/1` can reject it; and
- fan traffic into the single server GenServer, subscriber, and recipient
  connection mailboxes.

The registration timeout does not protect already registered connections and
there is no connection, command-rate, or mailbox limit.

Remediation:

- Use `active: :once` or a small `active: N` value and re-arm the socket only
  after processing.
- Enforce a socket-level line bound large enough for the supported IRCv3 tag
  section plus the 512-byte message section (for example 9 KiB), then retain
  the parser's more precise section checks.
- Add per-IP connection limits, command/token-bucket limits, idle timeouts, and
  overload disconnects.
- Monitor process mailbox sizes and shed abusive connections before memory
  pressure affects the VM.
- Add flood tests for complete lines and a no-newline oversized input.

References: [Erlang active socket guidance](https://www.erlang.org/docs/26/man/inet.html)
and [Erlang packet-size documentation](https://www.erlang.org/doc/apps/erts/erlang.html).

### SEC-004 — High — One stalled TLS handshake blocks all TLS accepts — Resolved

At the reviewed revision, the TLS acceptor performed `:ssl.handshake(socket)` synchronously, with the
default infinite timeout, before returning to `:ssl.transport_accept/1`
([server.ex](../lib/ircxd/server.ex#L2961)). A peer can establish TCP and then
stop during the TLS handshake. Because there is only one accept loop, no later
TLS client can be accepted.

Remediation:

- Move each accepted TLS handshake into a supervised, bounded worker.
- Call `:ssl.handshake/2` with a short configurable timeout.
- Limit concurrent handshakes per source and globally.
- Keep the accept loop independent from handshake errors.

The Erlang SSL documentation explicitly recommends the timeout form for real
servers to avoid denial of service:
[Erlang SSL documentation](https://www.erlang.org/docs/26/apps/ssl/ssl.pdf).

### SEC-005 — High — IRC casemapping is advertised but not enforced — Resolved

At the reviewed revision, the server advertised `CASEMAPPING=ascii`
([server.ex](../lib/ircxd/server.ex#L512)), but nickname collision checks use
exact binary matching
([server.ex](../lib/ircxd/server.ex#L125),
[server.ex](../lib/ircxd/server.ex#L153)). Direct-message routing, WHO/ISON,
MONITOR, mode targets, channels, and ban matching likewise use exact,
case-sensitive values. Channel maps are keyed by the original spelling
([server.ex](../lib/ircxd/server.ex#L1861)).

As a result, `Alice` and `alice` can coexist, as can `#Ops` and `#ops`, despite
being equivalent under the advertised mapping. This creates identity
impersonation and confused-deputy risks in clients. It can also bypass
nickname-targeted bans and cause channel policy to apply to a different
case-variant channel.

Remediation:

- Introduce one casemapping function selected from ISUPPORT policy.
- Key all identity and channel indexes by the folded value while preserving
  display spelling separately.
- Apply the same folding to nick/channel lookup, MONITOR, masks, invitations,
  history targets, and mode authorization.
- Add collision, routing, ban, and channel tests for ASCII letter variants.
- Either implement RFC1459 folding or stop accepting/configuring a mapping that
  is not consistently enforced.

Reference: [RFC 2812, sections 1.3 and 2.2](https://www.rfc-editor.org/rfc/rfc2812.html).

### SEC-006 — Medium — Cleartext credential authentication is allowed

The client can send `PASS`, WEBIRC passwords, OPER passwords, account
registration passwords, and SASL PLAIN while `tls: false`
([client.ex](../lib/ircxd/client.ex#L604),
[client.ex](../lib/ircxd/client.ex#L623)). Base64 encoding in SASL PLAIN
provides no confidentiality. The server also accepts PASS, PLAIN, and the
current EXTERNAL flow on its unencrypted listener
([connection.ex](../lib/ircxd/server/connection.ex#L149),
[connection.ex](../lib/ircxd/server/connection.ex#L205)).

Remediation:

- Reject credential-bearing commands on cleartext transports by default.
- Provide an explicit `allow_insecure_auth: true` compatibility escape hatch.
- Expose transport security in authenticator metadata.
- Document that a TLS-terminating proxy must preserve a trustworthy indication
  of the authenticated transport.

### SEC-007 — Medium — Authentication can consume adapter capacity

Authentication runs through a supervised adapter worker with a configurable
timeout and one callback at a time. The adapter owns its callback state and may
reject attempts using application-specific account or source tracking. The
server does not impose a rate or attempt limit; the metadata includes the peer
address for that policy. The server-password comparison also uses ordinary
equality ([server.ex](../lib/ircxd/server.ex#L189)).

Remediation:

- Keep authentication policy, including any rate or attempt tracking, in the
  application adapter.
- Add per-IP and per-account attempt limits and progressive backoff.
- Include peer IP/port, transport, TLS properties, and mechanism in metadata.
- Keep database pools and authentication concurrency bounded.
- Use a constant-time comparison for a configured shared server password, or
  store only a password verifier.

### SEC-008 — Medium — SCRAM iteration count can exhaust client CPU

The client must reject server-supplied SCRAM iteration counts outside its
safe range before calling PBKDF2. PBKDF2 currently runs synchronously in the
client process
([sasl.ex](../lib/ircxd/sasl.ex#L31),
[sasl.ex](../lib/ircxd/sasl.ex#L107)). A malicious or impersonated server can
send an extremely large value and consume a scheduler for a prolonged period.

Remediation:

- Use 4,096 as the minimum and 1,000,000 as the maximum; deployments with
  stricter CPU requirements can later choose a tighter application setting.
- Perform expensive derivation in a bounded worker with a timeout.
- Add tests for zero, below-minimum, excessive, and integer-overflow values.

RFC 7677 recommends at least 4096 iterations but does not require clients to
accept an unlimited value:
[RFC 7677](https://www.rfc-editor.org/rfc/rfc7677.html).

### SEC-009 — Medium — Attacker-controlled state can grow without bounds

Several cumulative structures have no quota or expiry:

- Server client batches can be opened repeatedly and left unfinished
  ([server.ex](../lib/ircxd/server.ex#L1524)).
- MONITOR targets accumulate across commands, and no `MONITOR` limit is
  advertised or enforced
  ([server.ex](../lib/ircxd/server.ex#L1617)).
- WHOWAS limits entries per nickname but not the number of nickname keys
  ([server.ex](../lib/ircxd/server.ex#L2410)).
- Connections, channels per user, channel bans, and concurrent users have no
  configured maxima.
- Adapter callbacks are serialized in one worker; applications should keep
  callback work bounded and apply their own persistence backpressure.
- A malicious upstream server can leave arbitrary client batch references open
  and grow multiline and metadata buffers
  ([client.ex](../lib/ircxd/client.ex#L1754),
  [client.ex](../lib/ircxd/client.ex#L2028)).

Individual IRC lines are bounded, but repeated valid commands bypass that
per-line protection.

Remediation:

- Add configurable global and per-connection limits with protocol-appropriate
  errors and cleanup.
- Advertise and enforce a finite `MONITOR=<limit>` value. The IRCv3 MONITOR
  specification defines numeric 734 for overflow.
- Expire unfinished batches and bound buffered batch bytes/messages.
- Bound WHOWAS globally by count and/or age.
- Keep adapter callback work bounded and apply explicit application-level
  backpressure or a durable queue owned by the host application.

Reference: [IRCv3 MONITOR specification](https://ircv3.net/specs/extensions/monitor).

### SEC-010 — Medium — The server always listens on every IPv4 interface — Resolved

The server now binds to `{127, 0, 0, 1}` by default and accepts a per-server
`ip` option for an explicit IPv4 bind address. The TLS and plain TCP listeners
use the same setting.

Applications exposing a wildcard bind should still apply firewall and proxy
policy, and must not trust forwarded addresses unless the proxy itself is
authenticated and restricted.

### SEC-011 — Medium — Client-side event processing is not isolated

The client socket also uses unbounded active mode. In addition, application
`handle_event/2` callbacks execute synchronously inside the client GenServer
without exception isolation
([client.ex](../lib/ircxd/client.ex#L2855)). A malicious server can flood events
or intentionally trigger a slow/raising handler, delaying PING handling or
terminating the client.

Remediation:

- Apply the flow-control changes from SEC-003 to client sockets.
- Run application effects in a separate, supervised, bounded process.
- Define callback timeout, failure, and queue-overflow behavior.
- Bound server-time ordering buffers and all batch aggregations.

## Existing safeguards

The following controls were present and effective within their stated scope:

- Incoming messages validate the 512-byte message section, IRCv3 tag-section
  size, command shape, and 15-parameter limit
  ([message.ex](../lib/ircxd/message.ex#L12)).
- Client outbound parameters reject embedded CR/LF, preventing command
  injection through normal client APIs
  ([client.ex](../lib/ircxd/client.ex#L2281)).
- WebSocket helpers reject multiple lines, enforce wire size, and require UTF-8
  for text frames
  ([web_socket.ex](../lib/ircxd/web_socket.ex#L37)).
- Channel history is globally bounded, and CHATHISTORY requires current channel
  membership
  ([server.ex](../lib/ircxd/server.ex#L475),
  [server.ex](../lib/ircxd/server.ex#L2550)).
- Redaction is limited to the original sender or a current channel operator
  ([server.ex](../lib/ircxd/server.ex#L2653)).
- Adapter callback exceptions are contained in a dedicated worker.
- DCC support only parses negotiation data and does not open sockets or write
  files. The documentation assigns consent, path validation, transfer limits,
  and endpoint policy to the host application.
- File-host helpers do not fetch URLs and reject cleartext upload URLs when the
  IRC transport is TLS. Host applications must still apply SSRF protections
  before fetching an advertised URL.
- No shell execution, unsafe term deserialization, runtime atom creation,
  dynamic code evaluation, or production credential logging was found.
- The committed private key is confined to `test/support/tls/` and is a test
  fixture; it must never be reused outside tests.

## Dependency and verification results

At the reviewed revision:

- `mix hex.audit` completed successfully with no retired packages or known Hex
  security advisories.
- `mix compile --warnings-as-errors` completed successfully.
- `mix test` completed with 395 tests, 0 failures, and 3 opt-in integration
  tests excluded by their normal tags.
- Runtime dependencies are limited to OTP applications (`logger` and `ssl`);
  Hex dependencies in the lock file are documentation tooling used only in
  development.
- The normal ExUnit suite excludes separately tagged external-services
  integration tests. Security regression tests should be added when the
  findings above are fixed; the current passing functional suite does not
  exercise these adversarial conditions.

Dependency scanning only detects published advisories. It does not establish
that project code or OTP itself is vulnerability-free, so the audit should run
in CI and the supported OTP release should remain patched.

## Recommended remediation order

1. Disable unsafe `EXTERNAL`, make TLS peer/hostname verification secure by
   default, and reject cleartext credentials.
2. Add socket packet bounds, active-once flow control, TLS handshake workers
   with timeouts, and connection/rate limits.
3. Normalize every nickname and channel operation through one casemapping
   index.
4. Move authentication and application callbacks out of the central protocol
   processes with bounded concurrency and queues.
5. Add quotas/expiry for batches, MONITOR, WHOWAS, channels, bans, history
   requests, and buffered client state.
6. Add adversarial tests and run dependency auditing continuously.

After those changes, repeat this review with network-level flood tests and
certificate-authentication tests against both direct TLS and the intended
production proxy topology.
