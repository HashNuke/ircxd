# Ircxd

Ircxd is an Elixir IRC client library intended for use inside other Elixir
applications.

The library currently provides:

- Modern IRC line parsing and serialization.
- IRCv3 message tag parsing, escaping, and serialization.
- Optional IRCv3 `msgid` duplicate marking hooks.
- Optional manual ordered flush for timestamped `server-time` events.
- Optional automatic timed flush for timestamp-ordered `server-time` events.
- TCP and implicit TLS transports.
- Optional reconnect after transport close.
- Registration with `CAP LS 302`, `NICK`, and `USER`.
- Capability request/ack flow for supported server capabilities.
- SASL PLAIN negotiation support.
- Configurable SASL failure policy: continue registration or abort with `QUIT`.
- SASL mechanism fallback across configured mechanisms such as `EXTERNAL` then `PLAIN`.
- Automatic `PING`/`PONG`.
- `JOIN`, `PART`, `TOPIC`, `MODE`, `KICK`, `PRIVMSG`, `NOTICE`, `TAGMSG`, `QUIT`, and raw command helpers.
- Outbound IRCv3 tagged messages for client-only tags and labeled responses.
- IRCv3 `BATCH`, labeled-response, identity, presence, and standard-reply events.
- IRCv3 labeled-response `ACK` events and batch-level labeled-response aggregation.
- IRCv3 labeled-response request lifecycle events for sent, acknowledged, and completed requests.
- Outbound IRCv3 `label` tags are only sent after `labeled-response` is negotiated.
- Outbound IRCv3 client-only tags are only sent after `message-tags` is negotiated.
- IRCv3 `MONITOR`, `SETNAME`, and invite notification helpers/events.
- IRCv3 Bot Mode helper, message tag, WHO, and WHOIS events.
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
- Draft IRCv3 chathistory command helpers and `TARGETS` events.
- Draft IRCv3 multiline receive aggregation and outbound multiline message helpers.
- CTCP encode/decode helpers.
- ISUPPORT, NAMES, source mask, casemapping, server-time, msgid, label, batch, and account helpers.
- Callback-style event delivery through `:notify` or `Ircxd.Handler`.

Storage, scrollback, notification persistence, and application state are not part
of this library. Consumers receive events and decide what to store.

## Usage

```elixir
{:ok, client} =
  Ircxd.start_link(
    host: "irc.libera.chat",
    port: 6697,
    tls: true,
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

Current tests cover the first compatibility slice from Modern IRC and IRCv3:

- Message format: tags, source, command, middle params, trailing params.
- IRCv3 tag escaping for `;`, space, CR, LF, and backslash.
- IRCv3 message tag data limits and duplicate-tag last-value handling.
- IRCv3 `TAGMSG` send and receive handling.
- Numeric replies such as `001`.
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
- Capability listing and ACK flow against InspIRCd.
- Capability `NAK`, `NEW`, and `DEL` handling against scripted servers.
- Channel join and bidirectional channel messaging against InspIRCd.
- IRCv3 `echo-message` self-echo and `server-time` metadata against InspIRCd.
- Nickname collision retry against InspIRCd.
- Optional reconnect after a transport close.
- SASL PLAIN client negotiation against a scripted IRC server.
- SASL failure policy for default continue and configured abort.
- SASL `EXTERNAL` payloads and mechanism fallback to `PLAIN`.
- Modern IRC state-change events: `NICK`, `JOIN`, `PART`, `QUIT`, `KICK`, `TOPIC`, `MODE`, and `ERROR`.
- IRCv3 `extended-join` account and realname metadata.
- IRCv3 `account-tag`, `account-notify`, `away-notify`, and `chghost` events.
- IRCv3 `multi-prefix` rank-ordered prefixes in `RPL_NAMREPLY`.
- IRCv3 Bot Mode `BOT` ISUPPORT mode helper, `bot` tag, WHO flag, and `335 RPL_WHOISBOT`.
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
- Draft IRCv3 chathistory selectors, command helpers, `CHATHISTORY TARGETS`, and batch-delivered history events.
- IRCv3 `BATCH` start/end tracking and batched message events.
- Draft IRCv3 multiline batch aggregation, `draft/multiline-concat`, and outbound multiline `PRIVMSG`/`NOTICE` helpers.
- IRCv3 labeled-response `ACK` and `labeled-response` batch aggregation.
- IRCv3 labeled-response request lifecycle tracking for outbound labeled commands.
- Rejection of outbound IRCv3 `label` tags when `labeled-response` was not negotiated.
- Rejection of outbound IRCv3 client-only tags when `message-tags` was not negotiated.
- Rejection of outbound IRCv3 client-only tags after `CAP DEL message-tags`.
- IRCv3 `FAIL`, `WARN`, and `NOTE` standard replies.
- WHO, WHOX, WHOIS, and WHOWAS parser/client event helpers.
- Outbound IRCv3 tagged messages.

This is not yet complete coverage of every IRCv3 extension. The next slices
should add broader real-server coverage for draft extensions.
