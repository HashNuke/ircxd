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
| Registration (`CAP`, `NICK`, `USER`, `PASS`, `005`, welcome numerics) | partial | `server_registration_test.exs`, `server_password_test.exs`, `server_isupport_test.exs`, `server_nick_change_test.exs`; handshake, ISUPPORT advertisement, duplicate nick policy, registered nickname changes with channel fan-out, password/464 rejection, nickname validation/432, configurable registration timeout, and post-registration USER protection/462 exist; add remaining policy cases |
| Core connection commands (`PING`, `PONG`, `QUIT`) | partial | `server_connection_test.exs`, `server_quit_test.exs`, `server_protocol_errors_test.exs`; explicit/unexpected QUIT, unknown-command 421, and pre-registration 451 exist, add malformed cases |
| Server information (`MOTD`, `LIST`, `LUSERS`, `VERSION`, `TIME`, `ADMIN`) | partial | `server_motd_test.exs`, `server_list_test.exs`, `server_lusers_test.exs`, `server_version_test.exs`, `server_time_test.exs`, `server_admin_test.exs`; configurable MOTD, channel LIST, live LUSERS, VERSION, TIME, and ADMIN numerics exist, add remaining query commands |
| Channels and identity (`JOIN`, `PART`, `INVITE`, `KICK`, `NAMES`, `WHO`, `WHOIS`, `TOPIC`, `MODE`, `LIST`) | partial | `server_channels_test.exs`, `server_topic_test.exs`, `server_validation_test.exs`, `server_mode_test.exs`, `server_list_test.exs`, `server_multi_join_test.exs`, `server_multi_part_test.exs`, `server_join_zero_test.exs`, `server_channel_lifecycle_test.exs`, `server_names_all_test.exs`, `server_join_idempotency_test.exs`, `server_invite_test.exs`, `server_invite_policy_test.exs`, `server_kick_test.exs`, `server_channel_modes_test.exs`, `server_operator_test.exs`, `server_topic_mode_test.exs`, `server_moderated_mode_test.exs`, `server_key_mode_test.exs`, `server_limit_mode_test.exs`, `server_voice_mode_test.exs`, `server_secret_mode_test.exs`, `server_ban_mode_test.exs`, `server_no_external_mode_test.exs`, `server_multi_prefix_test.exs`, `server_userhost_names_test.exs`, `server_implicit_names_test.exs`, `server_who_test.exs`, `server_whois_test.exs`; core state, `JOIN 0` all-channel PART, empty-channel state cleanup, implicit `353`/`366` JOIN NAMES, `no-implicit-names` opt-out, idempotent and multi-target JOIN/PART, member-authorized INVITE/341, operator-only INVITE for `+i` channels, KICK removal, invite-only `+i`/473 policy, topic-lock `+t` policy, non-member TOPIC `442` validation, moderated `+m`/404 message policy, explicit default `+n`/`-n` external-message policy, keyed `+k`/`475` JOIN policy, limited `+l`/471 capacity policy, `+v`/`-v` voice grants and `+` NAMES prefixes, secret `+s` member-aware LIST/NAMES/WHO visibility, wildcard `+b`/`-b` nick bans with `474` and `367`/`368` list numerics, nickname-targeted and no-mask WHO with `352`/`315`, negotiated multi-prefix `@+` NAMES output, negotiated userhost-in-names hostmasks, first-member operators/`@` NAMES prefixes, MODE/KICK/topic `482` enforcement, membership 442 validation, all-channel NAMES, WHO/WHOIS identity, target validation, read-only mode queries, and LIST numerics exist, add remaining channel policy/modes |
| Published messages (`PRIVMSG`, `NOTICE`, `TAGMSG`) | partial | `server_messaging_test.exs`, `server_isolation_test.exs`, `server_direct_message_test.exs`, `server_tagmsg_test.exs`, `server_tagmsg_policy_test.exs`, `server_message_tags_test.exs`, `server_message_errors_test.exs`, `server_message_target_test.exs`, `server_echo_message_test.exs`, `server_account_tag_test.exs`; channel/direct routing, negotiated sender echo, per-recipient account tags, tag preservation, shared membership/moderation/`+n` policy for `TAGMSG`, malformed policy, and target/membership errors exist, add remaining command validation |
| Input limits and malformed wire handling | partial | `server_limits_test.exs`, `server_registration_test.exs`, `server_protocol_errors_test.exs`; oversized lines return 417, unknown commands return 421, malformed JOIN/INVITE/KICK/PART return 461, and registration/command errors are covered, add remaining malformed parameter policy |
| Subscriber callback contract and failure isolation | implemented | `server_subscriber_test.exs`; callback state is serialized in a worker and slow/raising callbacks do not block server routing |
| Application-owned SASL authentication | partial | `server_authentication_test.exs`; PLAIN success/failure, serialized authenticator state, account propagation through WHOIS `330`, and standard `900 RPL_LOGGEDIN` metadata exist, add mechanisms and policy cases |
| Capability negotiation and `CAP LS/REQ/LIST/END` | partial | `server_tagmsg_test.exs`, `server_authentication_test.exs`, `server_capability_test.exs`, `server_server_time_test.exs`, `server_extended_join_test.exs`, `server_away_notify_test.exs`, `server_account_notify_test.exs`, `server_echo_message_test.exs`, `server_account_tag_test.exs`, `server_multi_prefix_test.exs`, `server_userhost_names_test.exs`, `server_implicit_names_test.exs`, `server_setname_test.exs`, `server_capability_disable_test.exs`, `server_capability_list_test.exs`, `server_invite_notify_test.exs`; LS/ACK/NAK/LIST/END, positive and negative capability requests, active-capability listing, message-tags/SASL/server-time/extended-join/away-notify/account-notify/account-tag/echo-message/multi-prefix/userhost-in-names/no-implicit-names/setname/invite-notify advertisement, capability-gated invite notifications, and negotiated per-connection capability state exist, add capability state policy cases |
| Message tags, server-time, and message IDs | partial | `server_message_tags_test.exs`, `server_server_time_test.exs`, `server_message_id_test.exs`, `server_account_tag_test.exs`; client-only tag relay, negotiated `time=YYYY-MM-DDThh:mm:ss.sssZ` server tags, per-recipient account tags, and shared server-generated `msgid` values for tagged recipients exist, add message-ID policy cases |
| SASL mechanisms beyond PLAIN | planned | `server_sasl_test.exs` |
| Account, away, monitor, and user-property tracking | partial | `server_authentication_test.exs`, `server_account_notify_test.exs`, `server_away_test.exs`, `server_away_notify_test.exs`, `server_monitor_test.exs`, `server_user_queries_test.exs`, `server_setname_test.exs`; application-owned account propagation, negotiated self/common-channel `ACCOUNT` notifications, negotiated AWAY fan-out with `305`/`306` and `away-notify`, negotiated realname changes via `SETNAME`, away-aware WHOIS `301`, MONITOR add/remove/clear/list/status with `730`/`731`/`732`/`733`, connect/disconnect notifications, and `ISON`/`USERHOST` replies with `303`/`302` exist, add remaining user-property tracking |
| Batches, multiline, history, and redaction | planned | focused feature test files |
| Standard replies and labeled responses | planned | focused feature test files |
| TLS listener and STS policy | partial | `server_tls_test.exs`; implicit TLS listeners accept `tls_options` and share the normal server protocol path, while certificate provisioning and STS policy remain host-owned |
| Persistence, moderation policy, and application side effects | host | subscriber/callback contract |
| irssi interoperability | partial | `scripts/run_irssi_server_check.sh`; irssi connects to a disposable `Ircxd.Server` in a named tmux session and receives a message sent by `Ircxd.Client`, while the existing `scripts/run_irssi_manual_check.sh` covers the external InspIRCd gate |

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
