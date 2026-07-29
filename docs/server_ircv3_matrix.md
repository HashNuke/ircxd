# IRC server implementation matrix

This matrix tracks the server-side work separately from the existing client
coverage. The ordering follows the [official IRCv3 specification index](https://ircv3.net/irc/),
which identifies Modern IRC as the core protocol and capability negotiation and
message tags as foundations for the extensions built on top of it.

Status values:

- `implemented`: behavior exists and has focused automated tests.
- `partial`: a narrow slice exists, with more protocol behavior required.
- `planned`: not implemented yet.
- `host`: intentionally delegated to the embedding application.

| Area | Status | Planned evidence |
|---|---|---|
| Supervision-tree lifecycle and ephemeral listeners | implemented | `Ircxd.Server`, `server_lifecycle_test.exs` |
| Multiple server-instance isolation | implemented | `server_lifecycle_test.exs` |
| Registration (`CAP`, `NICK`, `USER`, welcome numerics) | partial | `server_registration_test.exs`; add validation and timeout cases |
| Core connection commands (`PING`, `PONG`, `QUIT`) | partial | `server_connection_test.exs`; PING/PONG exists, add QUIT and cleanup |
| Channels (`JOIN`, `PART`, `NAMES`, `TOPIC`) | partial | `server_channels_test.exs`, `server_topic_test.exs`; core state exists, add validation and modes |
| Published messages (`PRIVMSG`, `NOTICE`, `TAGMSG`) | partial | `server_messaging_test.exs`, `server_isolation_test.exs`; PRIVMSG/NOTICE fan-out exists, add TAGMSG and direct targets |
| Subscriber callback contract and failure isolation | partial | `server_subscriber_test.exs`; add explicit crash/slow-callback isolation tests |
| Application-owned SASL authentication | partial | `server_authentication_test.exs`; PLAIN success/failure exist, add mechanisms and policy cases |
| Capability negotiation and `CAP LS/REQ/END` | partial | `server_capabilities_test.exs`; SASL advertisement/ACK is covered by authentication tests |
| Message tags, server-time, and message IDs | planned | `server_message_tags_test.exs` |
| SASL mechanisms beyond PLAIN | planned | `server_sasl_test.exs` |
| Account, away, monitor, and user-property tracking | planned | focused feature test files |
| Batches, multiline, history, and redaction | planned | focused feature test files |
| Standard replies and labeled responses | planned | focused feature test files |
| TLS listener and STS policy | planned | `server_tls_test.exs`; host certificate configuration remains host-owned |
| Persistence, moderation policy, and application side effects | host | subscriber/callback contract |
| irssi interoperability | partial | irssi is installed; run an opt-in manual/integration check after core commands stabilize |

## Subscriber contract

The server accepts a subscriber module and initialization argument in its
options. The subscriber receives every message the server publishes to clients,
along with server/channel metadata, so an embedding application can persist
messages or trigger other effects without the server owning a database.

The callback must be isolated from connection processes: a subscriber failure
must be observable and must not take down the listener or unrelated clients.

## Authentication contract

The server accepts an `authenticator: {module, init_arg}` option. The module
implements `Ircxd.Server.Authenticator`; its `authenticate/4` callback receives
the decoded SASL PLAIN username and password, connection metadata, and its own
state. The callback may query the embedding application's database and returns
an account value on success or a reason on failure. The server does not own
credentials, account persistence, or database connections.
