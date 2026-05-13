# Ircxd

Ircxd is an Elixir IRC client library intended for use inside other Elixir
applications.

The library currently provides:

- Modern IRC line parsing and serialization.
- Modern IRC command-token and parameter-count validation.
- IRCv3 message tag parsing, escaping, and serialization.
- Optional IRCv3 `msgid` duplicate marking hooks.
- Optional manual ordered flush for timestamped `server-time` events.
- Optional automatic timed flush for timestamp-ordered `server-time` events.
- TCP and implicit TLS transports.
- TLS Server Name Indication (SNI), with an optional override for IP or proxy connects.
- Optional reconnect after transport close.
- Registration with `CAP LS 302`, `NICK`, and `USER`.
- Optional server password registration with `PASS`.
- Capability request/ack flow for supported server capabilities.
- SASL PLAIN negotiation support.
- SASL SCRAM-SHA-256 negotiation support.
- Configurable SASL failure policy: continue registration or abort with `QUIT`.
- SASL mechanism fallback across configured mechanisms such as `EXTERNAL` then `PLAIN`.
- SASL v3.2 mechanism-list events from `908 RPL_SASLMECHS`.
- Automatic `PING`/`PONG`.
- Modern IRC helpers for registration, channel operations, mode queries, server/operator queries, service queries, user queries, messaging, and raw commands.
- Outbound IRCv3 tagged messages for client-only tags and labeled responses.
- IRCv3 `BATCH`, labeled-response, identity, presence, and standard-reply events.
- IRCv3 stable `netsplit` and `netjoin` batch aggregation events.
- IRCv3 labeled-response `ACK` events and batch-level labeled-response aggregation.
- IRCv3 labeled-response request lifecycle events for sent, acknowledged, and completed requests.
- IRCv3 account extended-ban mask helpers.
- Outbound IRCv3 `label` tags are only sent after `labeled-response` is negotiated.
- Outbound IRCv3 client-only tags are only sent after `message-tags` is negotiated.
- IRCv3 `MONITOR`, `SETNAME`, and invite notification helpers/events.
- IRCv3 Bot Mode helper, message tag, WHO, and WHOIS events.
- IRCv3 `+typing` client tag helper/events.
- IRCv3 `+reply` client tag helper and message metadata.
- Draft IRCv3 `+draft/react` and `+draft/unreact` client tag helpers/events.
- Draft IRCv3 `+draft/channel-context` helper and message metadata.
- IRCv3 `CLIENTTAGDENY` helpers for client-only tag UI decisions.
- IRCv3 STS policy parsing and CAP negotiation handling.
- IRCv3 `UTF8ONLY` outbound parameter enforcement.
- IRCv3 `no-implicit-names` negotiation with explicit `NAMES` helper/events.
- IRCv3 `multi-prefix` NAMES parsing.
- Draft IRCv3 account registration and verification command helpers/events.
- Draft IRCv3 pre-away `AWAY *` helper/events.
- Draft IRCv3 channel rename command helper/events.
- Draft IRCv3 message redaction command helper/events.
- Draft IRCv3 read marker command helpers/events.
- IRCv3 `userhost-in-names` NAMES parsing.
- Draft IRCv3 `metadata` command helpers, server messages, and key numerics.
- Draft IRCv3 metadata batch aggregation including standard `FAIL` entries.
- IRCv3 WebIRC startup support.
- IRCv3 WebSocket subprotocol, one-line payload helpers, and adapter behaviour.
- In-memory WebSocket adapter for adapter-boundary tests and embedders.
- Draft IRCv3 chathistory command helpers and `TARGETS` events.
- Draft IRCv3 multiline receive aggregation and outbound multiline message helpers.
- Draft IRCv3 client-initiated batch helper with required capability checks.
- Draft IRCv3 extended-isupport command helper and `draft/isupport` batch aggregation.
- Work-in-progress `soju.im/FILEHOST` ISUPPORT token helper.
- CTCP encode/decode helpers.
- DCC CTCP query parser/encoder helpers for `CHAT`, `SEND`, `RESUME`, and
  `ACCEPT` negotiation.
- Parsed DCC payloads on CTCP `PRIVMSG` and `NOTICE` events.
- DCC reverse/port-0 detection for host-owned connection policy.
- Modern IRC formatting control-code parser and stripper.
- ISUPPORT, NAMES, source mask, casemapping, server-time, msgid, label, batch, and account helpers.
- Callback-style event delivery through `:notify` or `Ircxd.Handler`.

Storage, scrollback, notification persistence, and application state are not part
of this library. Consumers receive events and decide what to store.

WebSocket socket lifecycle is also adapter-owned. `Ircxd.WebSocket` validates
the IRCv3 WebSocket subprotocol and one-line payload rules, then host
applications can provide adapters implementing `Ircxd.WebSocket.Adapter` for
Phoenix Channels, Cowboy, Bandit, or another stack.

## Usage

```elixir
{:ok, client} =
  Ircxd.start_link(
    host: "irc.libera.chat",
    port: 6697,
    tls: true,
    sni: "irc.libera.chat",
    nick: "myapp",
    username: "myapp",
    realname: "My App",
    caps: ["server-time", "echo-message"],
    notify: self()
  )

receive do
  {:ircxd, :registered} -> :ok
end

:ok = Ircxd.Client.join(client, "#elixir")
:ok = Ircxd.Client.privmsg(client, "#elixir", "hello")
```

## Local Compatibility Testing

The test suite expects InspIRCd on `127.0.0.1:6667` for integration tests.

The local InspIRCd used during development had these IRCv3 modules enabled:

```text
<module name="cap">
<module name="ircv3">
<module name="ircv3_servertime">
<module name="ircv3_msgid">
<module name="ircv3_echomessage">
<module name="ircv3_labeledresponse">
```

Run tests:

```bash
mix test
```

Manual irssi check:

```bash
tmux new-session -d -s ircxd-irssi "irssi -n irssiuser"
tmux send-keys -t ircxd-irssi "/connect 127.0.0.1 6667" Enter
tmux send-keys -t ircxd-irssi "/join #ircxd-manual" Enter
mix run -e '{:ok, pid} = Ircxd.start_link(host: "127.0.0.1", port: 6667, tls: false, nick: "ircxdmanual", username: "ircxdmanual", realname: "ircxd manual", caps: ["server-time", "echo-message"], notify: self()); receive do {:ircxd, :registered} -> :ok after 15000 -> exit(:timeout) end; Ircxd.Client.join(pid, "#ircxd-manual"); Process.sleep(500); Ircxd.Client.privmsg(pid, "#ircxd-manual", "hello from ircxd manual test"); Process.sleep(1000)'
tmux capture-pane -pt ircxd-irssi -S -120
```

Expected evidence in irssi:

```text
< ircxdmanual> hello from ircxd manual test
```

## Spec Coverage

See `docs/spec_audit.md` for the current prompt-to-artifact audit and known
remaining gaps.

Current tests cover the first compatibility slice from Modern IRC and IRCv3:

- Message format: tags, source, command, middle params, trailing params.
- Modern IRC command-token validation and 15-parameter limit enforcement.
- IRCv3 tag escaping for `;`, space, CR, LF, and backslash.
- IRCv3 message tag data limits and duplicate-tag last-value handling.
- IRCv3 `TAGMSG` send and receive handling.
- Typed registration numerics `001` through `004`.
- Source masks such as `nick!user@host` and server names.
- ISUPPORT `005` tokens and NAMES `353` prefixes.
- IRCv3 `userhost-in-names` full hostmask entries in NAMES replies.
- IRC casemapping: `ascii`, `rfc1459`, and `strict-rfc1459`.
- CTCP payloads.
- IRCv3 `time`, `msgid`, `label`, `batch`, and `account` tags.
- Optional IRCv3 `msgid` duplicate marking and `:duplicate_msgid` events.
- Optional buffering and timestamp-ordered manual flush for `server-time` events.
- Optional automatic timed flush for buffered `server-time` events.
- Wire size constants for the 512-byte IRC message limit.
- Client registration against InspIRCd.
- Typed registration numerics `001` through `004` against InspIRCd.
- Capability listing and ACK flow against InspIRCd.
- NAMES `353` and `366` numerics against InspIRCd.
- Modern IRC `PASS` startup ordering and core command helper serialization.
- Modern IRC helper serialization for operator, server-link, service, trace, status, and legacy query commands.
- Capability `NAK`, `NEW`, and `DEL` handling against scripted servers.
- Channel join and bidirectional channel messaging against InspIRCd.
- IRCv3 `echo-message` self-echo and `server-time` metadata against InspIRCd.
- IRCv3 `extended-join` account and realname metadata against InspIRCd.
- IRCv3 `away-notify` state changes against InspIRCd.
- Modern IRC `LIST` numerics against InspIRCd.
- Modern IRC `VERSION` and `ISON` numerics against InspIRCd.
- WHOX `354` numerics against InspIRCd.
- Channel mode `324` and creation time `329` numerics against InspIRCd.
- Topic `332` and `333` numerics against InspIRCd.
- Ban list `367` and `368` numerics against InspIRCd.
- Nickname collision retry against InspIRCd.
- Optional reconnect after a transport close.
- SASL PLAIN client negotiation against a scripted IRC server.
- SASL SCRAM-SHA-256 RFC 7677 payloads and scripted negotiation.
- SASL failure policy for default continue and configured abort.
- SASL `EXTERNAL` payloads and mechanism fallback to `PLAIN`.
- SASL v3.2 `908 RPL_SASLMECHS` parsing without treating the mechanism list as failure.
- Modern IRC state-change events: `NICK`, `JOIN`, `PART`, `QUIT`, `KICK`, `TOPIC`, `MODE`, and `ERROR`.
- Modern IRC away status numerics: `301`, `305`, and `306`.
- Modern IRC redirect, retry, operator, rehash, and STARTTLS numerics.
- Modern IRC stats uptime and invite-list numerics.
- Modern IRC `STATS` link/configuration-line numerics.
- Modern IRC `300 RPL_NONE` numeric.
- Modern IRC error numerics including `400`, `407`, `408`, `414`, and `415`.
- Modern IRC server-query numeric events for `LIST`, `MOTD`, `ADMIN`, `LUSERS`, `TIME`, `INFO`, `LINKS`, and `USERHOST`.
- Modern IRC numeric events for `VERSION`, `STATS`, `HELP`, user/channel modes, invites, and channel mask lists.
- Modern IRC topic query numeric events `331`, `332`, and `333`.
- Modern IRC numeric events for `ISON`, `SERVLIST`, `TRACE`, and `USERS`.
- Modern IRC typed error numeric events with code, target, reason, and raw parameters.
- IRCv3 `extended-join` account and realname metadata.
- IRCv3 `account-tag`, `account-notify`, `away-notify`, and `chghost` events.
- IRCv3 `multi-prefix` rank-ordered prefixes in `RPL_NAMREPLY`.
- IRCv3 Bot Mode `BOT` ISUPPORT mode helper, `bot` tag, WHO flag, and `335 RPL_WHOISBOT`.
- IRCv3 `sts` policy parsing, policy events, no `CAP REQ sts`, and ignored `CAP DEL sts`.
- IRCv3 SNI default and override TLS connection options.
- IRCv3 `UTF8ONLY` ISUPPORT handling that rejects outbound non-UTF-8 parameters.
- IRCv3 `ACCOUNTEXTBAN`/`EXTBAN` account ban mask construction.
- IRCv3 `no-implicit-names` explicit `NAMES` flow and `366 RPL_ENDOFNAMES` event.
- IRCv3 `+typing` client tag helper, status validation, and typed receive events.
- IRCv3 `+reply` client tag helper and `reply_to_msgid` metadata on messages.
- Draft IRCv3 `+draft/react`/`+draft/unreact` helpers and typed reaction events.
- Draft IRCv3 `+draft/channel-context` helpers and `channel_context` metadata on messages.
- IRCv3 `CLIENTTAGDENY` parsing including wildcard blocks and exemptions.
- IRCv3 `MONITOR` command helpers and `730`-`734` numeric events.
- IRCv3 `setname` command/events and `invite-notify` events.
- Draft IRCv3 `REGISTER`/`VERIFY` helpers, success/verification-required events, and required capability checks.
- Draft IRCv3 `pre-away` unspecified-away helper/events and required capability checks.
- Draft IRCv3 `RENAME` command helper and channel rename events.
- Draft IRCv3 `REDACT` command helper, redaction events, and required capability checks.
- Draft IRCv3 `MARKREAD` get/set helpers, read marker events, and required capability checks.
- Draft IRCv3 `metadata` key validation, `METADATA` command helpers, server events, and `760`/`761`/`766`/`770`/`771`/`772`/`774` numerics.
- Draft IRCv3 metadata batch aggregation with key-value, key-not-set, and standard `FAIL` entries.
- IRCv3 WebIRC parameter/option serialization and startup ordering before `CAP`.
- IRCv3 WebSocket `binary.ircv3.net`/`text.ircv3.net` subprotocols, CRLF-free single-line payload validation, and adapter dispatch.
- Modern IRC formatting controls for bold, italics, underline, strikethrough,
  monospace, reverse, numeric colors, hex colors, and reset.
- Draft IRCv3 chathistory selectors, command helpers, `CHATHISTORY TARGETS`, and batch-delivered history events.
- IRCv3 `BATCH` start/end tracking and batched message events.
- IRCv3 stable `netsplit` and `netjoin` batch aggregation.
- Draft IRCv3 multiline batch aggregation, `draft/multiline-concat`, and outbound multiline `PRIVMSG`/`NOTICE` helpers.
- Draft IRCv3 client-initiated `BATCH` helper with nested-batch rejection.
- Draft IRCv3 extended-isupport `ISUPPORT` helper and `draft/isupport` batch aggregation.
- Work-in-progress `soju.im/FILEHOST` ISUPPORT parsing and upload URL safety checks.
- IRCv3 labeled-response `ACK` and `labeled-response` batch aggregation.
- IRCv3 labeled-response request lifecycle tracking for outbound labeled commands.
- IRCv3 labeled-response lifecycle completion for single standard replies.
- Rejection of outbound IRCv3 `label` tags when `labeled-response` was not negotiated.
- Rejection of outbound IRCv3 client-only tags when `message-tags` was not negotiated.
- Rejection of outbound IRCv3 client-only tags after `CAP DEL message-tags`.
- IRCv3 `FAIL`, `WARN`, and `NOTE` standard replies.
- WHO, WHOX, WHOIS, and WHOWAS parser/client event helpers, including optional WHOIS numerics and `314`/`369`.
- Outbound IRCv3 tagged messages.

This is not yet complete coverage of every IRCv3 extension. The next slices
should add broader real-server coverage for draft extensions.
