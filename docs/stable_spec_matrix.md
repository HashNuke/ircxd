# ircxd Stable Spec Matrix

This matrix is the work queue for stable Modern IRC and IRCv3 support. It is
intentionally grouped by spec area so future commits can land as coherent
sections, not as isolated token-by-token fixes.

Status meanings:

- `covered`: implemented with automated tests in this repository.
- `partial`: implemented for the library boundary, but more behavior or
  real-server coverage is still needed.
- `host`: intentionally delegated to embedding applications through callbacks,
  adapters, or emitted events.
- `pending`: no complete implementation or evidence yet.

## Modern IRC

| Area | Status | Evidence | Next grouped work |
| --- | --- | --- | --- |
| Message framing and serialization | covered | `lib/ircxd/message.ex`, `test/ircxd/message_test.exs`, `test/ircxd/client_wire_size_test.exs` | Keep parser and wire-limit cases together. |
| Source parsing | covered | `lib/ircxd/source.ex`, `test/ircxd/source_test.exs` | Add only if Modern IRC source grammar changes. |
| Registration and connection lifecycle | covered | `lib/ircxd/client.ex`, `test/ircxd/client_registration_numeric_test.exs`, `test/ircxd/client_reconnect_test.exs`, `test/ircxd/client_integration_test.exs` | Expand with real-server edge cases as a registration slice. |
| Capability negotiation | covered | `test/ircxd/client_cap_lifecycle_test.exs` | Future CAP work should be batched as `CAP lifecycle and value semantics`. |
| ISUPPORT parsing and helpers | covered | `lib/ircxd/isupport.ex`, `test/ircxd/isupport_test.exs` | Future ISUPPORT work should be batched as `ISUPPORT registry helpers`. |
| Channel commands and numerics | covered | `test/ircxd/client_core_commands_test.exs`, `test/ircxd/client_topic_numeric_test.exs`, `test/ircxd/client_integration_test.exs` | Group uncommon numerics by command family. |
| Server and user queries | covered | `test/ircxd/client_query_events_test.exs`, `test/ircxd/client_server_query_events_test.exs`, `test/ircxd/who_test.exs`, `test/ircxd/whois_test.exs`, `test/ircxd/user_host_test.exs` | Group WHO/WHOIS/WHOWAS/USERHOST additions together. |
| Error numerics | covered | `test/ircxd/client_error_numeric_test.exs`, `test/ircxd/client_rfc2812_numeric_test.exs` | Stable Modern IRC error numerics are covered; continue auditing uncommon vendor numerics only when encountered. |
| Formatting codes | covered | `lib/ircxd/formatting.ex`, `test/ircxd/formatting_test.exs` | No current stable gap. |
| CTCP and DCC parsing | host | `lib/ircxd/ctcp.ex`, `lib/ircxd/dcc.ex`, `test/ircxd/ctcp_test.exs`, `test/ircxd/dcc_test.exs`, `test/ircxd/client_dcc_test.exs`, `docs/host_boundaries.md` | DCC CTCP parsing is covered; direct DCC sockets and file policy stay host-owned. |

## IRCv3 Stable

| Area | Status | Evidence | Next grouped work |
| --- | --- | --- | --- |
| Capability Negotiation 302 | covered | `test/ircxd/client_cap_lifecycle_test.exs` | Keep future CAP changes in one lifecycle/value-semantics commit. |
| Message Tags | covered | `test/ircxd/message_test.exs`, `test/ircxd/tags_test.exs`, `test/ircxd/client_tagged_messages_test.exs` | Add tag parsing/gating cases as a message-tags slice. |
| Client-only tags: reply and typing | covered | `test/ircxd/client_reply_tag_test.exs`, `test/ircxd/client_tagmsg_test.exs` | Draft client-only tags are tracked separately. |
| SASL | covered | `test/ircxd/client_sasl_test.exs`, `test/ircxd/client_sasl_fallback_test.exs`, `test/ircxd/client_sasl_scram_test.exs`, `test/ircxd/sasl_test.exs`, `test/ircxd/client_services_integration_test.exs` | Keep new mechanism work grouped with scripted and services-backed coverage. |
| Account tracking | covered | `test/ircxd/client_identity_events_test.exs`, `test/ircxd/account_extban_test.exs`, `test/ircxd/client_account_extban_test.exs`, `test/ircxd/client_integration_test.exs`, `test/ircxd/client_services_integration_test.exs` | Real `account-notify`, `account-tag`, login, and logout are covered by opt-in services integration. |
| Away notifications | covered | `test/ircxd/client_presence_events_test.exs`, `test/ircxd/client_integration_test.exs` | No current stable gap. |
| Batch and netsplit/netjoin | covered | `test/ircxd/client_batch_test.exs`, `test/ircxd/client_net_batch_test.exs`, `test/ircxd/batch_test.exs` | Keep future batch-type work grouped. |
| Bot mode | covered | `test/ircxd/client_bot_mode_test.exs`, `test/ircxd/isupport_test.exs` | No current stable gap. |
| Changing user properties | covered | `test/ircxd/client_presence_events_test.exs`, `test/ircxd/client_setname_invite_test.exs` | No current stable gap. |
| Echo message | covered | `test/ircxd/client_integration_test.exs`, `test/ircxd/client_reply_tag_test.exs` | No current stable gap. |
| Invite notify | covered | `test/ircxd/client_setname_invite_test.exs` | No current stable gap. |
| Labeled response | covered | `test/ircxd/client_labeled_response_test.exs`, `test/ircxd/client_labeled_response_batch_test.exs`, `test/ircxd/client_labeled_response_lifecycle_test.exs` | Add any missing completion cases as one labeled-response slice. |
| Listing users: multi-prefix, userhost-in-names, WHOX, no-implicit-names | covered | `test/ircxd/client_userhost_names_test.exs`, `test/ircxd/client_no_implicit_names_test.exs`, `test/ircxd/who_test.exs`, `test/ircxd/client_integration_test.exs` | No current stable gap. |
| Message IDs | covered | `test/ircxd/client_msgid_dedupe_test.exs`, `test/ircxd/client_reply_tag_test.exs` | No current stable gap. |
| MONITOR and extended-monitor | covered | `test/ircxd/monitor_test.exs`, `test/ircxd/client_monitor_test.exs`, `test/ircxd/client_extended_monitor_test.exs` | No current stable gap. |
| Server time | covered | `test/ircxd/client_server_time_order_test.exs`, `test/ircxd/client_server_time_auto_flush_test.exs`, `test/ircxd/client_integration_test.exs` | No current stable gap. |
| SNI | covered | `test/ircxd/client_tls_test.exs` | No current stable gap. |
| Standard replies | covered | `test/ircxd/standard_reply_test.exs`, `test/ircxd/client_standard_reply_test.exs`, `test/ircxd/client_integration_test.exs`, `test/ircxd/client_standard_replies_integration_test.exs` | Parser, scripted client events, real negotiation, and opt-in real `FAIL` emission are covered. |
| STS | host | `test/ircxd/sts_test.exs`, `test/ircxd/client_sts_test.exs`, `docs/host_boundaries.md` | Policy parsing and client event/error boundaries are covered; cross-restart persistence and enforcement stay host-owned. |
| UTF8ONLY | covered | `test/ircxd/client_utf8_only_test.exs` | No current stable gap. |
| WEBIRC | covered | `test/ircxd/webirc_test.exs`, `test/ircxd/client_webirc_test.exs` | No current stable gap. |
| WebSocket | host | `lib/ircxd/web_socket.ex`, `lib/ircxd/web_socket/adapter.ex`, `test/ircxd/web_socket_test.exs`, `docs/host_boundaries.md` | Subprotocol, payload, send, and close adapter boundaries are covered; Phoenix/Cowboy/Bandit server adapters stay host-owned or optional-package work. |

## Stable Work Queue

No stable Modern IRC or IRCv3 protocol implementation slice is currently queued.
Host-owned surfaces remain documented in `docs/host_boundaries.md`; add adapter
behaviour tests when new optional adapter APIs are introduced.

## Draft Policy

No new draft feature expansion should be started while stable coverage remains
in this queue. Existing draft code stays tested, but draft work is limited to
regression fixes unless explicitly reprioritized.
