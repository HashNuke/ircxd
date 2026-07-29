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
| Supervision-tree lifecycle and ephemeral listeners | implemented | `Ircxd.Server`, `server_lifecycle_test.exs`; multiple children use distinct configured IDs |
| Multiple server-instance isolation | implemented | `server_lifecycle_test.exs` |
| Registration (`CAP`, `NICK`, `USER`, `PASS`, welcome numerics) | partial | `server_registration_test.exs`, `server_password_test.exs`; handshake, duplicate nick policy, password/464 rejection, nickname validation/432, and configurable registration timeout exist; add remaining policy cases |
| Core connection commands (`PING`, `PONG`, `QUIT`) | partial | `server_connection_test.exs`, `server_quit_test.exs`, `server_protocol_errors_test.exs`; explicit/unexpected QUIT, unknown-command 421, and pre-registration 451 exist, add malformed cases |
| Channels (`JOIN`, `PART`, `NAMES`, `TOPIC`, `MODE`) | partial | `server_channels_test.exs`, `server_topic_test.exs`, `server_validation_test.exs`, `server_mode_test.exs`; core state, target validation, and read-only mode queries exist, add channel modes/policy |
| Published messages (`PRIVMSG`, `NOTICE`, `TAGMSG`) | partial | `server_messaging_test.exs`, `server_isolation_test.exs`, `server_direct_message_test.exs`, `server_tagmsg_test.exs`, `server_message_tags_test.exs`; channel/direct routing, tagged TAGMSG, and tagged PRIVMSG/NOTICE preservation exist, add validation |
| Input limits and malformed wire handling | partial | `server_limits_test.exs`, `server_registration_test.exs`, `server_protocol_errors_test.exs`; oversized lines return 417 and registration/command errors are covered, add malformed parameter policy |
| Subscriber callback contract and failure isolation | implemented | `server_subscriber_test.exs`; callback state is serialized in a worker and slow/raising callbacks do not block server routing |
| Application-owned SASL authentication | partial | `server_authentication_test.exs`; PLAIN success/failure exist, add mechanisms and policy cases |
| Capability negotiation and `CAP LS/REQ/END` | partial | `server_tagmsg_test.exs`, `server_authentication_test.exs`, `server_capability_test.exs`; LS/ACK/NAK/END and message-tags/SASL advertisement exist, add capability state policy cases |
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

The callback runs in a dedicated serialized worker owned by the server. A slow
or failing subscriber cannot block connection processes, take down the
listener, or affect unrelated clients.

## Authentication contract

The server accepts an `authenticator: {module, init_arg}` option. The module
implements `Ircxd.Server.Authenticator`; its `authenticate/4` callback receives
the decoded SASL PLAIN username and password, connection metadata, and its own
state. The callback may query the embedding application's database and returns
an account value on success or a reason on failure. The server does not own
credentials, account persistence, or database connections.
