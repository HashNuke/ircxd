# Modern IRC Audit

Checked against <https://modern.ircdocs.horse/> on 2026-05-14.

The Modern IRC Client Protocol document describes the client protocol as a
living specification and notes that it is still work-in-progress. For `ircxd`,
the current stable completion target treats this source as the reference for
widely implemented IRC client behaviour, while host-owned surfaces stay
documented separately.

## Covered Areas

Implementation evidence is recorded in `docs/spec_audit.md` and grouped in
`docs/stable_spec_matrix.md`. The current implementation covers these Modern IRC
areas:

- Message format: tags, source, command, parameters, validation, serialization,
  and wire-size boundaries.
- Connection setup and registration: `PASS`, `NICK`, `USER`, registration
  numerics, `PING`/`PONG`, and reconnect boundaries.
- Feature advertisement and capability negotiation: `005 RPL_ISUPPORT`, typed
  ISUPPORT helpers, `CAP LS 302`, multiline capability lists, `REQ`, `ACK`,
  `NAK`, `NEW`, `DEL`, and post-registration capability changes.
- Client messages: channel operations, server queries, user queries, operator
  commands, service queries, messaging, and optional messages.
- Numerics: registration, topic/list/names/mode replies, WHO/WHOIS/WHOWAS,
  away/account/SASL numerics, common errors, and compatibility numerics tracked
  by the test suite.
- Formatting, CTCP parsing, and DCC CTCP payload parsing.

## Host Boundaries

Direct DCC sockets/files, STS persistence, WebSocket server lifecycle, storage,
notifications, and other application policy remain host-owned. Those boundaries
are documented in `docs/host_boundaries.md`, `docs/dcc_boundaries.md`,
`docs/sts_boundaries.md`, `docs/websocket_adapters.md`, and
`docs/embedding_events.md`.
