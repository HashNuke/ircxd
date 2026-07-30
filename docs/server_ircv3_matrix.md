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
| Registration (`CAP`, `NICK`, `USER`, `PASS`, `005`, welcome numerics) | partial | `server_registration_test.exs`, `server_password_test.exs`, `server_isupport_test.exs`, `server_nick_change_test.exs`, `server_registration_query_validation_test.exs`, `server_casemapping_test.exs`; handshake, ISUPPORT advertisement including default `PREFIX=(ov)@+` and `CHANMODES=b,k,l,imnpst`, casemapping-aware duplicate nick policy, registered nickname changes with channel fan-out, password/464 rejection, nickname validation/432, missing `NICK`/`USER`/`PASS`/`AUTHENTICATE` parameter errors, configurable registration timeout, and post-registration USER protection/462 exist; add remaining policy cases |
| Core connection commands (`PING`, `PONG`, `QUIT`) | partial | `server_connection_test.exs`, `server_quit_test.exs`, `server_protocol_errors_test.exs`, `server_registration_query_validation_test.exs`; client PING/PONG round trips, accepted client PONG replies, explicit/unexpected QUIT, unknown-command 421, pre-registration 451, and missing-PING-parameter 461 behavior exist, add remaining malformed cases |
| Server information (`MOTD`, `LIST`, `LUSERS`, `VERSION`, `TIME`, `ADMIN`, `INFO`, `HELP`, `LINKS`, `STATS`, `WHOWAS`) | partial | `server_motd_test.exs`, `server_list_test.exs`, `server_list_filter_test.exs`, `server_lusers_test.exs`, `server_version_test.exs`, `server_time_test.exs`, `server_admin_test.exs`, `server_info_test.exs`, `server_help_test.exs`, `server_links_test.exs`, `server_stats_test.exs`, `server_whowas_test.exs`; configurable MOTD, wildcard channel LIST masks with visibility filtering, live LUSERS, VERSION, TIME, ADMIN, configurable INFO lines through `371`/`374`, configurable HELP text through `704`/`705`/`706`, standalone-server LINKS through `364`/`365`, uptime `STATS u` through `242`/`219`, and bounded in-memory nick history through `314`/`369` exist, add remaining query commands |
| Channels and identity (`JOIN`, `PART`, `INVITE`, `KICK`, `NAMES`, `WHO`, `WHOIS`, `TOPIC`, `MODE`, `LIST`) | partial | Existing focused channel tests plus `server_casemapping_test.exs`; core state, channel modes, visibility, authorization, and advertised `CASEMAPPING` normalization for nicknames, channels, mode parameters, masks, and command targets exist; add remaining channel policy/modes |
| Published messages (`PRIVMSG`, `NOTICE`, `TAGMSG`) | partial | `server_messaging_test.exs`, `server_isolation_test.exs`, `server_direct_message_test.exs`, `server_multi_target_message_test.exs`, `server_tagmsg_test.exs`, `server_tagmsg_policy_test.exs`, `server_message_tags_test.exs`, `server_message_errors_test.exs`, `server_message_target_test.exs`, `server_echo_message_test.exs`, `server_account_tag_test.exs`; channel/direct and comma-separated multi-target routing, negotiated sender echo, per-recipient account tags, tag preservation, shared membership/moderation/`+n` policy for `TAGMSG`, malformed policy, and target/membership errors exist, add remaining command validation |
| Input limits and malformed wire handling | partial | `server_limits_test.exs`, `server_transport_security_test.exs`, and protocol-validation tests; sockets use bounded line packets and `active: :once`, commands are synchronously backpressured, connection/rate limits close excess clients, oversized complete IRC messages return 417, oversized unterminated input is closed by the transport, and malformed command numerics are covered; add remaining malformed parameter policy |
| Adapter callback contract and failure isolation | implemented | `server_adapter_test.exs`, `server_subscriber_test.exs`; shared adapter state is serialized in a worker, slow/raising callbacks do not block server routing, and adapter initialization failures return structured startup errors without leaving the listener active |
| Application-owned SASL authentication | partial | `server_authentication_test.exs`; structured adapter initialization failures, no SASL advertisement when no callback is configured, unsupported-mechanism `904` responses, mechanism-state reset after credential attempts, PLAIN success/failure, serialized adapter state, raised/malformed callback failure isolation, account propagation through WHOIS `330`, standard `900 RPL_LOGGEDIN` metadata, and `AUTHENTICATE *` abort handling with `906` exist, add mechanisms and policy cases |
| Capability negotiation and `CAP LS/REQ/LIST/END` | partial | `server_tagmsg_test.exs`, `server_authentication_test.exs`, `server_capability_test.exs`, `server_server_time_test.exs`, `server_extended_join_test.exs`, `server_away_notify_test.exs`, `server_account_notify_test.exs`, `server_echo_message_test.exs`, `server_account_tag_test.exs`, `server_multi_prefix_test.exs`, `server_userhost_names_test.exs`, `server_implicit_names_test.exs`, `server_setname_test.exs`, `server_capability_disable_test.exs`, `server_capability_list_test.exs`, `server_invite_notify_test.exs`, `server_labeled_response_test.exs`, `server_batch_test.exs`; LS/ACK/NAK/LIST/END, positive and negative capability requests, missing `CAP REQ` parameter `461` handling, active-capability listing, message-tags/SASL/server-time/extended-join/away-notify/account-notify/account-tag/echo-message/multi-prefix/userhost-in-names/no-implicit-names/setname/invite-notify/labeled-response/batch advertisement, recipient-aware client batch framing, capability-gated invite notifications, labeled WHOIS replies, and negotiated per-connection capability state exist, add capability state policy cases |
| Message tags, server-time, and message IDs | partial | `server_message_tags_test.exs`, `server_server_time_test.exs`, `server_message_id_test.exs`, `server_account_tag_test.exs`; client-only tag relay, negotiated `time=YYYY-MM-DDThh:mm:ss.sssZ` server tags, per-recipient account tags, and shared server-generated `msgid` values for tagged recipients exist, add message-ID policy cases |
| SASL mechanisms beyond PLAIN | partial | `server_authentication_test.exs`; opt-in SASL `EXTERNAL` requires mutual TLS with a verified client certificate and supplies the certificate and SHA-256 fingerprint to application-owned identity policy; SCRAM remains |
| Account, away, monitor, and user-property tracking | partial | `server_authentication_test.exs`, `server_account_notify_test.exs`, `server_away_test.exs`, `server_away_notify_test.exs`, `server_monitor_test.exs`, `server_user_queries_test.exs`, `server_setname_test.exs`; application-owned account propagation, negotiated self/common-channel `ACCOUNT` notifications, negotiated AWAY fan-out with `305`/`306` and `away-notify`, negotiated realname changes via `SETNAME`, away-aware WHOIS `301`, MONITOR add/remove/clear/list/status with `730`/`731`/`732`/`733`, connect/disconnect notifications, and `ISON`/`USERHOST` replies with `303`/`302` exist, add remaining user-property tracking |
| Batches, multiline, history, and redaction | partial | `server_batch_test.exs`, `server_multiline_test.exs`, `server_chat_history_test.exs`, `server_chat_history_targets_test.exs`, `server_redaction_test.exs`; client-originated `BATCH` start/end framing and `draft/multiline` messages are relayed to actual recipients, bounded member-only `CHATHISTORY LATEST`/`BEFORE`/`AFTER`/`AROUND`/`BETWEEN` replies and visible `TARGETS` discovery are served from in-memory channel history, authors/operators can redact stored channel messages with capability-gated relay, and unauthorized members receive `REDACT_FORBIDDEN`, while broader moderation policy remains |
| Standard replies and labeled responses | partial | `server_labeled_response_test.exs`, `server_standard_reply_test.exs`; labeled WHOIS and PING/PONG response sequences preserve request labels and negotiated clients receive `FAIL ... UNKNOWN_COMMAND` alongside `421`, while broader labeled-command and standard-reply coverage remains |
| TLS listener and STS policy | partial | `server_tls_test.exs`; implicit TLS listeners use bounded concurrent handshakes with a configurable timeout, can require trusted client certificates for EXTERNAL, and share the normal protocol path; certificate provisioning and STS policy remain host-owned |
| Persistence, moderation policy, and application side effects | host | adapter callback contract |
| irssi interoperability | partial | `scripts/run_irssi_server_check.sh`; irssi connects to a disposable `Ircxd.Server` in a named tmux session and receives a message sent by `Ircxd.Client`, while the existing `scripts/run_irssi_manual_check.sh` covers the external InspIRCd gate |

Private channel mode `+p` is covered by `server_private_mode_test.exs`: it
uses the private `*` NAMES symbol and hides non-member LIST results while
remaining distinguishable from secret mode `+s`.

## Adapter contract

The server accepts one adapter module and initialization argument in its
options. The adapter receives every message the server publishes to clients,
along with server/channel metadata, and may also authenticate SASL credentials.
Its callback state is shared, so applications can keep message handling and
authentication attempt policy together without the server owning a database.

Callbacks run in a dedicated worker owned by the server. A slow or failing
callback cannot block connection processes or take down the listener.

## Authentication contract

The adapter implements `Ircxd.Server.Adapter`; its `authenticate/4` callback receives
the decoded SASL PLAIN username and password, connection metadata, and its own
state. The callback may query the embedding application's database and returns
an account value on success or a reason on failure. The server does not own
credentials, account persistence, or database connections.

SASL EXTERNAL is disabled unless the server is started with
`external_auth: true` on a TLS listener configured with `verify: :verify_peer`
and a client-certificate trust store. Authentication metadata identifies the
mechanism and transport and includes the verified peer certificate plus its
SHA-256 fingerprint. The application authenticator remains responsible for
mapping the submitted authorization identity to that certificate.
