# IRCv3 Index Audit

Checked against <https://ircv3.net/irc/> on 2026-05-14.

The 2026-05-14 recheck did not change the stable versus work-in-progress
classification used by `docs/stable_spec_matrix.md`.

This file records how the current IRCv3 index is classified for `ircxd` work.
It is a companion to `docs/stable_spec_matrix.md`; implementation evidence stays
in the matrix and `docs/spec_audit.md`.

## Stable Index Items

- Capability Negotiation and cap-notify.
- Message Tags.
- SASL v3.1 and v3.2.
- Account tracking: account-extban, account-notify, account-tag, extended-join.
- Away Notifications.
- Batches and the stable netsplit/netjoin batch types.
- Bot Mode.
- Changing User Properties: chghost and setname.
- Client-only tags: reply and typing.
- Echo Message.
- Invite Notify.
- Labeled Responses.
- Listing Users: multi-prefix, userhost-in-names, WHOX, no-implicit-names.
- Message IDs.
- Monitor and Extended Monitor.
- Server Time.
- Standard Replies.
- Strict Transport Security.
- UTF8ONLY.
- WebIRC.
- WebSocket.

## Work-In-Progress / Draft Index Items

These are not part of the current stable-only completion target. Existing
helpers remain tested, but new expansion needs an explicit scope change.

- Account Registration.
- Client-initiated batches.
- Chathistory command.
- Channel Rename.
- Message Redaction.
- Read Marker.
- Pre-away.
- Channel-context client-only tag.
- React client-only tag.
- Extended ISUPPORT.
- Network icon ISUPPORT.
- Metadata v2.
- Multiline messages.
- Server Name Indication.

## Deprecated Index Items

- STARTTLS is deprecated by the IRCv3 index and is not implemented as an `ircxd`
  protocol feature. `ircxd` uses implicit TLS and STS boundary handling instead.
