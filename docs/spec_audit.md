# ircxd Spec Audit

This file tracks implementation status against Modern IRC and the IRCv3 spec
index. It is intentionally evidence-based: each completed area points to code or
tests in this repository. Passing `mix test` is necessary, but it is not by
itself proof that the full protocol surface is complete.

## Current Evidence

- Core parser and serializer: `lib/ircxd/message.ex`, `test/ircxd/message_test.exs`.
- Core client process and event delivery: `lib/ircxd/client.ex`, `lib/ircxd/handler.ex`.
- Modern IRC command helpers and numerics: `test/ircxd/client_core_commands_test.exs`,
  `test/ircxd/client_registration_numeric_test.exs`,
  `test/ircxd/client_server_query_events_test.exs`,
  `test/ircxd/client_modern_numeric_events_test.exs`,
  `test/ircxd/client_error_numeric_test.exs`,
  `test/ircxd/client_topic_numeric_test.exs`.
- Local InspIRCd coverage: `test/ircxd/client_integration_test.exs`.
- IRCv3 stable capability flow and extensions: `test/ircxd/client_cap_lifecycle_test.exs`,
  `test/ircxd/client_tagged_messages_test.exs`,
  `test/ircxd/client_sasl_test.exs`,
  `test/ircxd/client_sasl_scram_test.exs`,
  `test/ircxd/client_identity_events_test.exs`,
  `test/ircxd/client_presence_events_test.exs`,
  `test/ircxd/client_batch_test.exs`,
  `test/ircxd/client_net_batch_test.exs`,
  `test/ircxd/client_monitor_test.exs`,
  `test/ircxd/client_sts_test.exs`,
  `test/ircxd/client_utf8_only_test.exs`,
  `test/ircxd/client_webirc_test.exs`,
  `test/ircxd/web_socket_test.exs`.
- IRCv3 draft/work-in-progress helpers: `test/ircxd/client_metadata_test.exs`,
  `test/ircxd/client_metadata_batch_test.exs`,
  `test/ircxd/client_chat_history_test.exs`,
  `test/ircxd/client_multiline_test.exs`,
  `test/ircxd/client_channel_rename_test.exs`,
  `test/ircxd/client_message_redaction_test.exs`,
  `test/ircxd/client_read_marker_test.exs`,
  `test/ircxd/client_account_registration_test.exs`,
  `test/ircxd/client_pre_away_test.exs`,
  `test/ircxd/client_react_tag_test.exs`,
  `test/ircxd/client_channel_context_test.exs`.

## Modern IRC Status

Implemented and tested:

- Message framing, tags, source, command validation, parameter parsing, and
  byte-limit helpers.
- Formatting control-code parsing/stripping for bold, italics, underline,
  strikethrough, monospace, reverse, numeric colors, hex colors, and reset.
- Registration: `PASS`, `NICK`, `USER`, `001` through `004`, PING/PONG.
- Capability negotiation core through `CAP LS 302`, `REQ`, `ACK`, `NAK`, `NEW`,
  and `DEL`.
- Channel operations: `JOIN`, `PART`, `TOPIC`, `NAMES`, `LIST`, `INVITE`,
  `KICK`, `MODE`, topic numerics, name replies, channel modes, and mask lists.
- Server/user queries: `MOTD`, `VERSION`, `ADMIN`, `LUSERS`, `TIME`, `STATS`,
  `HELP`, `INFO`, `LINKS`, `WHO`, `WHOX`, `WHOIS`, `WHOWAS`, `USERHOST`,
  `ISON`, `TRACE`, `USERS`, and `SERVLIST` response events.
- Operator/server/service helper commands: `OPER`, `KILL`, `SQUERY`,
  `CONNECT`, `SQUIT`, `REHASH`, `RESTART`, `SUMMON`, `WALLOPS`.
- Common error numerics as typed `:irc_error` events.

Remaining Modern IRC gaps:

- Some legacy numerics are still typed only generically or raw if not commonly
  used by clients.
- `MODE` has helper support for setting modes, but mode-query helpers still use
  `raw/3` for parameter-shape edge cases.
- No DCC/XDCC implementation; DCC is outside the main client/server protocol
  but listed in the local spec references.

## IRCv3 Stable Status

Implemented and tested:

- Capability negotiation and cap-notify lifecycle.
- Message Tags, client-only tags, label tag gating, and client-tag-deny.
- SASL `PLAIN`, `EXTERNAL`, and `SCRAM-SHA-256`, including mechanism list
  numeric `908` and fallback behavior.
- Account tracking: `account-tag`, `account-notify`, `extended-join`,
  account extban helpers.
- Presence/property updates: `away-notify`, `chghost`, `setname`,
  `invite-notify`.
- Batches, netsplit/netjoin aggregation, labeled-response ACK/batch/request
  lifecycle.
- Bot mode helpers and WHO/WHOIS bot indicators.
- Echo-message, server-time ordering, message IDs and optional duplicate
  marking.
- Multi-prefix, userhost-in-names, no-implicit-names, WHOX.
- MONITOR and extended-monitor events.
- Standard replies: `FAIL`, `WARN`, `NOTE`.
- STS policy parsing and SNI TLS options.
- UTF8ONLY outbound validation.
- WEBIRC and WebSocket protocol-boundary helpers with an adapter behaviour.

Remaining IRCv3 stable gaps:

- Full WebSocket transport adapters are intentionally not bundled yet; only the
  adapter behaviour and payload validation exist.
- More real-server coverage is still desirable for capabilities not advertised
  by the local InspIRCd config, especially account services and standard
  replies.
- STS is parsed and exposed, but automatic policy persistence/enforcement is
  left to host applications.

## Draft / Work-In-Progress Status

Implemented and tested:

- Metadata command helpers, numerics, and metadata batch aggregation.
- Chathistory selectors, target replies, and batch-delivered history events.
- Multiline receive aggregation and outbound multiline helpers.
- Client-initiated batch helper with required capability checks and nested-batch
  rejection.
- Extended-isupport command helper and `draft/isupport` batch aggregation.
- Work-in-progress `soju.im/FILEHOST` ISUPPORT token helper and upload URL
  safety checks.
- Channel rename, message redaction, read markers, account registration,
  pre-away, draft reactions, and draft channel-context helpers.

Remaining draft/WIP gaps:

- Draft implementations should be rechecked before release because draft specs
  may change.

## Real-Server Coverage

Current local InspIRCd integration covers:

- Registration, `001` through `004`, ISUPPORT, NAMES, JOIN, PRIVMSG.
- `server-time`, `echo-message`, `extended-join`, `away-notify`.
- `LIST`, `VERSION`, `ISON`, WHOX, channel modes, topics, and ban lists.
- Nickname collision retry.

Remaining real-server work:

- Add coverage for standard replies if a deterministic InspIRCd command/module
  path is available.
- Add service/account-backed tests if the local InspIRCd config is extended with
  services suitable for SASL/account-notify/account-tag.
- Keep integration connection count under the local connection cap; prefer
  extending existing integration tests when possible.
