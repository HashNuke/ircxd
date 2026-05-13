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
| Server and user queries | covered | `test/ircxd/client_query_events_test.exs`, `test/ircxd/client_server_query_events_test.exs`, `test/ircxd/who_test.exs`, `test/ircxd/whois_test.exs` | Group WHO/WHOIS/WHOWAS additions together. |
| Error numerics | partial | `test/ircxd/client_error_numeric_test.exs`, `test/ircxd/client_rfc2812_numeric_test.exs` | Continue auditing uncommon implementation-specific numerics as `Modern numeric coverage` slices. |
| Formatting codes | covered | `lib/ircxd/formatting.ex`, `test/ircxd/formatting_test.exs` | No current stable gap. |
| CTCP and DCC parsing | partial | `lib/ircxd/ctcp.ex`, `lib/ircxd/dcc.ex`, `test/ircxd/ctcp_test.exs`, `test/ircxd/dcc_test.exs`, `test/ircxd/client_dcc_test.exs` | Direct DCC sockets and file policy stay host-owned. |

## IRCv3 Stable

| Area | Status | Evidence | Next grouped work |
| --- | --- | --- | --- |
| Capability Negotiation 302 | covered | `test/ircxd/client_cap_lifecycle_test.exs` | Keep future CAP changes in one lifecycle/value-semantics commit. |
| Message Tags | covered | `test/ircxd/message_test.exs`, `test/ircxd/tags_test.exs`, `test/ircxd/client_tagged_messages_test.exs` | Add tag parsing/gating cases as a message-tags slice. |
| Client-only tags: reply and typing | covered | `test/ircxd/client_reply_tag_test.exs`, `test/ircxd/client_tagmsg_test.exs` | Draft client-only tags are tracked separately. |
| SASL | covered | `test/ircxd/client_sasl_test.exs`, `test/ircxd/client_sasl_fallback_test.exs`, `test/ircxd/client_sasl_scram_test.exs`, `test/ircxd/sasl_test.exs` | Real service-backed auth remains a real-server gap. |
| Account tracking | covered | `test/ircxd/client_identity_events_test.exs`, `test/ircxd/account_extban_test.exs`, `test/ircxd/client_account_extban_test.exs` | Add service-backed tests as one account-services slice. |
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
| Standard replies | partial | `test/ircxd/standard_reply_test.exs`, `test/ircxd/client_standard_reply_test.exs`, `test/ircxd/client_integration_test.exs` | Real-server negotiation is covered; add real `FAIL`/`WARN`/`NOTE` emission only when a deterministic InspIRCd path is available. |
| STS | partial | `test/ircxd/sts_test.exs`, `test/ircxd/client_sts_test.exs` | Policy persistence and enforcement are host-owned, but should get adapter docs/tests if an API is added. |
| UTF8ONLY | covered | `test/ircxd/client_utf8_only_test.exs` | No current stable gap. |
| WEBIRC | covered | `test/ircxd/webirc_test.exs`, `test/ircxd/client_webirc_test.exs` | No current stable gap. |
| WebSocket | partial | `lib/ircxd/web_socket/adapter.ex`, `test/ircxd/web_socket_test.exs` | Add Phoenix/Cowboy adapter examples only as adapter packages or optional modules. |

## Stable Work Queue

1. `Modern numeric coverage`: continue auditing uncommon Modern IRC and RFC2812
   numerics, then add typed events/tests in grouped commits.
2. `Real-server standard replies`: find a deterministic InspIRCd module or
   command path for actual `FAIL`, `WARN`, or `NOTE` emission and add an
   integration test.
3. `Real-server account services`: extend local services/config if practical,
   then test SASL/account-tag/account-notify against a real server.
4. `Host-boundary docs and adapter tests`: document why storage, STS
   persistence, DCC transport, and WebSocket transport stay outside core
   `ircxd`, and add adapter behaviour tests where useful.

## Draft Policy

No new draft feature expansion should be started while stable coverage remains
in this queue. Existing draft code stays tested, but draft work is limited to
regression fixes unless explicitly reprioritized.
