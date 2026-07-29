# Ircxd.Server implementation plan

## Goal

Add an embeddable IRC server namespace to this library without changing the
existing client API. Applications start each server as a normal child in their
own supervision tree, and multiple server instances must be isolated and able
to listen on different (or independently configured) endpoints.

## Design constraints

- Keep all server modules under `Ircxd.Server`.
- Expose a supervision-tree-friendly `start_link/1` and child specification.
- Keep listener, connection, protocol state, and application callbacks
  separately testable.
- Use the existing `Ircxd.Message` representation and wire-size rules where
  appropriate, while handling server-specific registration and numerics.
- Tests must drive the server with `Ircxd.Client`; raw sockets are limited to
  focused transport/error tests where the client cannot express the case.
- Validate interoperability with irssi after the scripted client suite works.

## TDD tasks

1. [x] Define the public server lifecycle API and child spec with tests for
   starting/stopping one server, two isolated instances, and multiple
   independently identified children in one supervisor.
2. [x] Add a TCP listener/acceptor boundary with tests using an ephemeral port,
   clean shutdown, and port-bind failure behavior.
3. [ ] Implement per-connection registration (`NICK`, `USER`, `PASS`, `CAP`)
   and test the complete handshake through `Ircxd.Client`. Basic handshake,
   SASL gating, duplicate-nick rejection, and configured server-password
   acceptance/rejection are covered; add remaining validation and timeout cases.
   Nickname grammar and configurable registration timeouts are now covered.
   Repeated `USER` commands after registration now return `462` without changing identity.
4. [ ] Implement identity and channel state with tests for `JOIN`, `PART`,
   `PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `PING`, and `QUIT`. JOIN/PART/NAMES,
   PRIVMSG/NOTICE/TOPIC, PING/PONG, and explicit QUIT cleanup slices are covered.
   Read-only user and channel MODE queries and unexpected-disconnect QUIT
   cleanup are now covered as interoperability slices.
   Tagged `PRIVMSG`/`NOTICE` fan-out now preserves IRCv3 message tags.
   `LIST` now reports channel membership counts and topics.
   Comma-separated JOIN targets are now processed independently.
   Comma-separated PART targets now share the supplied part reason.
   Configured MOTD delivery is now covered with standard numerics.
   NAMES without a target now enumerates all known channels.
   LUSERS now reports registered-user and channel counts.
   VERSION now returns configured server identity and implementation details.
   Registration now advertises configurable ISUPPORT tokens via `005`.
   TIME now returns a parseable UTC timestamp.
   ADMIN now returns configurable location and email information.
   WHO now reports tracked username and realname identity for channel members.
   WHOIS now returns tracked user and server identity details.
   Successful SASL authentication now tracks the application account and exposes it through WHOIS `330`.
   Successful SASL authentication now also returns standard `900 RPL_LOGGEDIN` account metadata.
   Repeated JOIN requests are idempotent and do not publish duplicate JOIN events.
   `KICK` now broadcasts removal and updates channel membership state.
   `INVITE` now sends `341` to the inviter and an INVITE event to the target.
   Channel mode `+i` now blocks uninvited JOIN with `473` and consumes invites on JOIN.
   The first channel member is an operator, shown as `@` in NAMES; MODE and KICK now require operator authority.
   Channel mode `+t` now restricts topic changes to operators with `482` enforcement.
   Channel mode `+m` now restricts channel messages to operators with `404` enforcement; voice grants remain planned.
   Channel mode `+k` now stores a channel key and rejects incorrect JOIN keys with `475`.
   Channel mode `+l` now rejects JOINs at capacity with `471` and supports removing the limit.
   Channel modes `+v`/`-v` now grant and revoke moderated-channel speaking rights; voiced users appear as `+` in NAMES.
   `AWAY` now tracks per-connection presence, broadcasts updates, and returns `305`/`306` status numerics.
   `MONITOR` now supports add/remove/clear/list/status and online/offline notifications.
   WHOIS now includes `301 RPL_AWAY` when the target has an away message.
   `ISON` and `USERHOST` now answer online-user and user-host queries with `303` and `302`.
   The server now advertises `server-time`, tracks negotiated capabilities per
   connection, and adds millisecond UTC `time` tags to outbound messages for
   clients that request it.
   Tagged recipients now receive shared server-generated `msgid` values for
   each relayed message.
   Negotiated `extended-join` clients now receive account and realname JOIN
   parameters, while legacy clients retain the one-parameter form.
   `away-notify` is now advertised and AWAY fan-out is limited to clients that
   negotiated the capability.
   `account-notify` now reports the authenticated client’s account after SASL
   registration and on post-registration account changes to common-channel
   clients.
   `echo-message` is now negotiated per connection; senders only receive
   their own `PRIVMSG`, `NOTICE`, or `TAGMSG` when they request it.
   `account-tag` now adds authenticated account metadata to relayed messages
   for opted-in recipients and removes it for recipients without the feature.
5. [x] Implement initial server-to-client event fan-out and isolation tests
   proving clients on different server instances cannot observe one another.
   Continue extending the command surface.
6. [x] Add a configurable subscriber callback and test that published messages
   reach the embedding application with connection metadata. Callback state is
   serialized in a dedicated worker so slow or failing persistence cannot block
   the listener or command routing.
7. [ ] Add configurable callbacks/handler hooks and test callback failures and
   connection cleanup without taking down the listener.
8. [x] Add an authentication contract for SASL and test database-backed host
   callbacks, success, failure, and account metadata without embedding a DB.
9. [ ] Add protocol limits and malformed-input tests, including line size,
   registration timeouts, unknown commands, and nick/channel validation.
   Registration timeouts, nickname validation, unknown commands, and the
   pre-registration command gate are now covered. Oversized wire lines now
   return `417` and are covered with a focused transport test.
   Malformed `PRIVMSG` now returns `411`/`412`; malformed `NOTICE` remains silent.
   PART membership validation now returns `442` for non-members.
   PRIVMSG target validation now returns `401`, `403`, or `404` as appropriate.
10. [x] Run the full ExUnit suite, then run an irssi manual/integration check;
   document supported behavior and known boundaries.
11. [ ] Commit each coherent TDD slice with a detailed rationale and push every
   commit to the configured remote.

The server-side protocol matrix is maintained in `docs/server_ircv3_matrix.md`.

## Progress log

| Date | Change | Evidence |
|---|---|---|
| 2026-07-29 | Plan created on `server`; implementation not started | `plans/server.md` |
| 2026-07-29 | Added `Ircxd.Server` listener, connection registration, and split lifecycle/registration tests | `lib/ircxd/server.ex`, `lib/ircxd/server/connection.ex`, `test/ircxd/server_*_test.exs` |
| 2026-07-29 | Added IRCv3 server tracking matrix and subscriber-contract boundary | `docs/server_ircv3_matrix.md` |
| 2026-07-29 | Added subscriber callback and application-owned PLAIN SASL authentication with success/failure tests | `Ircxd.Server.Subscriber`, `Ircxd.Server.Authenticator`, `test/ircxd/server_subscriber_test.exs`, `test/ircxd/server_authentication_test.exs` |
| 2026-07-29 | Added channel `PRIVMSG`/`NOTICE` fan-out, connection `PING`/`PONG`, and cross-instance subscriber isolation | `test/ircxd/server_messaging_test.exs`, `test/ircxd/server_connection_test.exs`, `test/ircxd/server_isolation_test.exs` |
| 2026-07-29 | Verified irssi 1.4.5 can connect to an ephemeral `Ircxd.Server` listener; server observed one live connection | `mix run` + `irssi` compatibility check |
| 2026-07-29 | Added NAMES replies and PART fan-out with preserved reasons | `test/ircxd/server_channels_test.exs` |
| 2026-07-29 | Added channel topic publication and topic state | `test/ircxd/server_topic_test.exs` |
| 2026-07-29 | Added QUIT fan-out and removal from channel membership/NAMES state | `test/ircxd/server_quit_test.exs` |
| 2026-07-29 | Added nickname ownership and `433` retry behavior | `test/ircxd/server_registration_test.exs` |
| 2026-07-29 | Added direct nickname-target `PRIVMSG` and `NOTICE` routing | `test/ircxd/server_direct_message_test.exs` |
| 2026-07-29 | Added `message-tags` capability advertisement/ACK and tagged `TAGMSG` fan-out | `test/ircxd/server_tagmsg_test.exs` |
| 2026-07-29 | Added channel-target validation and `403 ERR_NOSUCHCHANNEL` | `test/ircxd/server_validation_test.exs` |
| 2026-07-29 | Added configured server-password registration with `PASS`/`464` tests | `test/ircxd/server_password_test.exs` |
| 2026-07-29 | Full ExUnit suite and irssi 1.4.5 connection smoke check pass; registered the server matrix as ExDoc extra | `mix test`, `mix run` irssi check, `mix.exs` |
| 2026-07-29 | Isolated subscriber callbacks in a serialized worker and covered slow/failing callback behavior | `Ircxd.Server.SubscriberWorker`, `test/ircxd/server_subscriber_test.exs` |
| 2026-07-29 | Re-ran full tests, irssi compatibility, and protocol microbenchmarks after subscriber isolation | `mix test`, `mix run` irssi check, `mix run bench/ircxd.exs` |
| 2026-07-29 | Added nickname grammar validation (`432`) and configurable incomplete-registration timeouts | `test/ircxd/server_registration_test.exs` |
| 2026-07-29 | Made repeated JOIN requests idempotent and added a regression test for duplicate event suppression | `test/ircxd/server_join_idempotency_test.exs` |
| 2026-07-29 | Rejected post-registration `USER` changes with `462 ERR_ALREADYREGISTERED` and preserved connection identity | `test/ircxd/server_registration_test.exs` |
| 2026-07-29 | Added channel `KICK` handling with broadcast/removal and a client-driven membership regression test | `test/ircxd/server_kick_test.exs` |
| 2026-07-29 | Added member-authorized channel `INVITE` delivery with `341` and a client-driven target notification test | `test/ircxd/server_invite_test.exs` |
| 2026-07-29 | Added invite-only channel mode `+i`, invitation tracking, and `473` JOIN policy coverage | `test/ircxd/server_channel_modes_test.exs` |
| 2026-07-29 | Added first-member channel operators, `@` NAMES prefixes, `482` enforcement for MODE/KICK, and deterministic operator-order tests | `test/ircxd/server_operator_test.exs` |
| 2026-07-29 | Added topic-lock mode `+t` and verified non-operator topic changes receive `482` | `test/ircxd/server_topic_mode_test.exs` |
| 2026-07-29 | Added moderated channel mode `+m` and verified non-operator message rejection while preserving operator fan-out | `test/ircxd/server_moderated_mode_test.exs` |
| 2026-07-29 | Added keyed channel mode `+k`, key-aware JOIN handling, and `475` rejection coverage | `test/ircxd/server_key_mode_test.exs` |
| 2026-07-29 | Added limited channel mode `+l`, numeric limit tracking, and `471` capacity rejection coverage | `test/ircxd/server_limit_mode_test.exs` |
| 2026-07-29 | Added voice grants for moderated channels, `+` NAMES prefixes, and voice cleanup on membership removal | `test/ircxd/server_voice_mode_test.exs` |
| 2026-07-29 | Added server AWAY state, channel presence fan-out, and standard away/unaway status replies | `test/ircxd/server_away_test.exs` |
| 2026-07-29 | Added MONITOR tracking with `730`/`731` notifications, `732`/`733` list replies, and connect/disconnect tests | `test/ircxd/server_monitor_test.exs` |
| 2026-07-29 | Added away-state WHOIS replies with `301 RPL_AWAY` coverage | `test/ircxd/server_away_test.exs` |
| 2026-07-29 | Revalidated away-aware WHOIS with 62 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated MONITOR presence behavior with 62 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated AWAY presence behavior with 60 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added `ISON` and `USERHOST` online-user query replies with focused client event coverage | `test/ircxd/server_user_queries_test.exs` |
| 2026-07-29 | Revalidated `ISON`/`USERHOST` with 63 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added negotiated IRCv3 `server-time` support with per-connection outbound timestamp tags | `test/ircxd/server_server_time_test.exs` |
| 2026-07-29 | Revalidated `server-time` with 64 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 capability negotiation against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added shared server-generated IRCv3 `msgid` tags for relayed messages with focused client-driven coverage | `test/ircxd/server_message_id_test.exs` |
| 2026-07-29 | Revalidated message-ID routing with 65 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 receiving a live relayed message after `message-tags` negotiation | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added negotiated `extended-join` JOIN parameters with legacy-client compatibility coverage | `test/ircxd/server_extended_join_test.exs` |
| 2026-07-29 | Revalidated `extended-join` with 67 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 joining a live channel after capability negotiation | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added negotiated `away-notify` fan-out with opt-in and legacy-client coverage | `test/ircxd/server_away_notify_test.exs`, `test/ircxd/server_away_test.exs` |
| 2026-07-29 | Revalidated `away-notify` with 68 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 capability negotiation plus live AWAY state | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added negotiated self `ACCOUNT` notifications after application-owned SASL authentication | `test/ircxd/server_account_notify_test.exs` |
| 2026-07-29 | Revalidated `account-notify` with 69 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 capability negotiation against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added common-channel `ACCOUNT` fan-out when a registered user changes accounts, with client-driven re-authentication coverage | `test/ircxd/server_account_notify_test.exs` |
| 2026-07-29 | Revalidated common-channel account-notify behavior with 70 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 negotiating the capability and joining a live channel | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added capability-correct sender echo behavior for `PRIVMSG`, `NOTICE`, and `TAGMSG` with opt-in/out coverage | `test/ircxd/server_echo_message_test.exs` |
| 2026-07-29 | Revalidated `echo-message` with 71 focused server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 receiving a live relayed message after capability negotiation | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Added per-recipient IRCv3 `account-tag` routing for authenticated messages with tagged and untagged client coverage | `test/ircxd/server_account_tag_test.exs` |
| 2026-07-29 | Revalidated voice and moderated-channel policy with 59 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated limited-channel policy with 58 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated keyed-channel policy with 57 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated moderated-mode routing with 56 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated topic-lock policy with 55 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated operator permissions with 54 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated `+i` channel policy with 53 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated INVITE with 52 server tests, the full ExUnit suite, formatting checks, and the existing irssi 1.4.5 smoke gate | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated KICK with 51 server tests, the full ExUnit suite, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, named tmux irssi check |
| 2026-07-29 | Revalidated registration identity protection with 50 server tests, formatting checks, and the full ExUnit suite | `mix format --check-formatted`, `mix test test/ircxd/server_*_test.exs`, `mix test` |
| 2026-07-29 | Propagated successful authenticator account values into server identity state and WHOIS `330` replies | `test/ircxd/server_authentication_test.exs` |
| 2026-07-29 | Added `900 RPL_LOGGEDIN` for successful application-owned SASL authentication | `test/ircxd/server_authentication_test.exs` |
| 2026-07-29 | Revalidated SASL login metadata with 62 server tests, the full ExUnit suite, formatting checks, and irssi 1.4.5 against a disposable named-tmux server | `mix test`, `mix format --check-formatted`, named tmux irssi check |
| 2026-07-29 | Revalidated authenticated-account propagation with formatting checks, 50 server tests, and the full ExUnit suite | `mix format --check-formatted`, `mix test test/ircxd/server_*_test.exs`, `mix test` |
| 2026-07-29 | Revalidated registration hardening with 23 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added `CAP NAK` responses for unsupported capability requests | `test/ircxd/server_capability_test.exs` |
| 2026-07-29 | Revalidated capability handling with 24 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added distinct child IDs for multiple supervised servers and documented the embedding API | `test/ircxd/server_lifecycle_test.exs`, `README.md` |
| 2026-07-29 | Revalidated the supervised-server embedding change with 25 server tests and the full suite | `mix format --check-formatted`, `mix test` |
| 2026-07-29 | Added `421` unknown-command and `451` pre-registration command errors | `test/ircxd/server_protocol_errors_test.exs` |
| 2026-07-29 | Revalidated protocol errors with 27 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added read-only `MODE` query replies (`221` user modes and `324` channel modes) | `test/ircxd/server_mode_test.exs` |
| 2026-07-29 | Revalidated MODE interoperability with 28 server tests, the full suite, and irssi; stabilized asynchronous TAGMSG capability setup | `mix test`, `mix run` irssi check, `test/ircxd/server_tagmsg_test.exs` |
| 2026-07-29 | Added `417` handling for oversized IRC wire lines | `test/ircxd/server_limits_test.exs` |
| 2026-07-29 | Revalidated input limits with 29 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Broadcast synthetic QUIT messages for unexpected disconnects and prevent duplicate explicit QUIT cleanup | `test/ircxd/server_quit_test.exs` |
| 2026-07-29 | Revalidated disconnect cleanup with 30 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Preserved IRCv3 tags while routing channel `PRIVMSG` and `NOTICE` messages | `test/ircxd/server_message_tags_test.exs` |
| 2026-07-29 | Accepted `CAP END` and made socket-send failures terminate connections cleanly | `test/ircxd/server_capability_test.exs`, `Ircxd.Server.Connection` |
| 2026-07-29 | Revalidated tagged message routing and capability/transport hardening with 32 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added `LIST` channel discovery with `321`/`322`/`323` numerics | `test/ircxd/server_list_test.exs` |
| 2026-07-29 | Added comma-separated multi-target `JOIN` handling | `test/ircxd/server_multi_join_test.exs` |
| 2026-07-29 | Added comma-separated multi-target `PART` handling with reason preservation | `test/ircxd/server_multi_part_test.exs` |
| 2026-07-29 | Revalidated multi-target PART with 35 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added configurable MOTD delivery with `375`/`372`/`376` numerics | `test/ircxd/server_motd_test.exs` |
| 2026-07-29 | Revalidated MOTD support with 36 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added no-target `NAMES` enumeration for all known channels | `test/ircxd/server_names_all_test.exs` |
| 2026-07-29 | Added live `LUSERS` counts with `251`–`255` replies | `test/ircxd/server_lusers_test.exs` |
| 2026-07-29 | Revalidated LUSERS with 38 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added `VERSION` support with the standard `351` reply | `test/ircxd/server_version_test.exs` |
| 2026-07-29 | Revalidated VERSION with 39 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added configurable registration ISUPPORT tokens with `005` | `test/ircxd/server_isupport_test.exs`, `README.md` |
| 2026-07-29 | Added standard malformed-message handling for `PRIVMSG` and `NOTICE` | `test/ircxd/server_message_errors_test.exs` |
| 2026-07-29 | Revalidated message validation with 42 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added `442 ERR_NOTONCHANNEL` for PART membership validation | `test/ircxd/server_validation_test.exs` |
| 2026-07-29 | Revalidated channel membership validation with 47 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added target-aware `PRIVMSG` errors for missing nicks/channels and non-members | `test/ircxd/server_message_target_test.exs` |
| 2026-07-29 | Revalidated message target policy with 48 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Revalidated JOIN idempotency with 49 server tests, the full suite, irssi 1.4.5, and refreshed protocol benchmarks; tagged `PRIVMSG` parsing measured 669.19 ms per 100k iterations (149,434 ops/s, p95 752.58 ms) | `mix test`, named tmux irssi check, `mix run bench/ircxd.exs` |
| 2026-07-29 | Revalidated ISUPPORT registration with 40 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added `TIME` support with standard `391` replies | `test/ircxd/server_time_test.exs` |
| 2026-07-29 | Revalidated TIME with 43 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added configurable `ADMIN` information with `256`–`259` replies | `test/ircxd/server_admin_test.exs`, `README.md` |
| 2026-07-29 | Revalidated ADMIN with 44 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added channel `WHO` identity replies with `352`/`315` | `test/ircxd/server_who_test.exs` |
| 2026-07-29 | Revalidated WHO identity handling with 45 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Added `WHOIS` identity replies with `311`/`312`/`318` | `test/ircxd/server_whois_test.exs` |
| 2026-07-29 | Made message-tags tests order-independent when registration and CAP ACK events race | `test/ircxd/server_tagmsg_test.exs`, `test/ircxd/server_message_tags_test.exs` |
| 2026-07-29 | Revalidated WHOIS and capability-test stability with 46 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Revalidated all-channel NAMES with 37 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Revalidated multi-target JOIN with 34 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
| 2026-07-29 | Revalidated LIST support with 33 server tests, the full suite, and irssi connectivity | `mix test`, `mix run` irssi check |
