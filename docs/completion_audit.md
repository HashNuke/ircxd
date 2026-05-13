# ircxd Completion Audit

This audit maps the original project request to repository artifacts and test
gates. It separates the current stable-only completion target from draft/WIP
IRCv3 features, which are intentionally not being expanded unless reprioritized.

## Success Criteria

| Requirement | Evidence | Status |
| --- | --- | --- |
| Elixir library named `ircxd` in `~/projects/ircxd` | `mix.exs`, `lib/ircxd.ex`, `lib/ircxd/client.ex` | Covered |
| Usable by other Elixir apps | Public `Ircxd.start_link/1`, `Ircxd.Client` helpers, `Ircxd.Handler`, `notify: pid` event delivery, `docs/host_boundaries.md` | Covered |
| IRC v2 / Modern IRC client support | Parser, serializer, command helpers, numerics, CTCP/DCC parsing, formatting, ISUPPORT, and client lifecycle tests listed in `docs/spec_audit.md` and `docs/stable_spec_matrix.md` | Covered for core protocol; direct DCC sockets/files are host-owned |
| IRCv3 stable support | Stable matrix rows in `docs/stable_spec_matrix.md`; tests for CAP, tags, SASL, account tracking, presence, batch, labeled-response, monitor, STS boundaries, UTF8ONLY, WEBIRC, WebSocket boundaries, and standard replies | Covered for stable protocol |
| IRCv3 draft/WIP support | `docs/ircv3_index_audit.md` plus existing draft helper tests for metadata, chathistory, multiline, channel rename, redaction, read markers, account registration, pre-away, reactions, channel context, extended-isupport, and SNI option handling | Partial by policy; drafts are not current completion scope |
| Local InspIRCd compatibility tests | `test/ircxd/client_integration_test.exs` against `127.0.0.1:6667` | Covered |
| Services-backed IRCv3 tests | `scripts/run_services_integration.sh`, `test/ircxd/client_services_integration_test.exs` | Covered by opt-in gate |
| Real standard-replies emission test | `scripts/run_standard_replies_integration.sh`, `test/ircxd/client_standard_replies_integration_test.exs` | Covered by opt-in gate |
| Automated tests | Parser/unit tests, scripted IRC server tests, local InspIRCd tests, and opt-in disposable real-server fixtures | Covered |
| Storage/application behavior handled by embedders | `docs/host_boundaries.md` documents storage, notifications, STS persistence, WebSocket server lifecycle, and DCC transfer policy as host-owned | Covered |

## Verification Gates

Run all current gates:

```bash
scripts/run_verification_gates.sh
```

Default suite:

```bash
mix test
```

Expected current result:

```text
253 tests, 0 failures (3 excluded)
```

Opt-in real standard-replies fixture:

```bash
scripts/run_standard_replies_integration.sh
```

Expected current result:

```text
1 test, 0 failures
```

Opt-in services fixture:

```bash
scripts/run_services_integration.sh
```

Expected current result:

```text
2 tests, 0 failures
```

## Remaining Boundaries

- DCC transport sockets, file writes, consent prompts, and bandwidth policy are
  host-owned. `ircxd` parses and emits DCC CTCP payloads.
- STS policy persistence and upgrade enforcement across application restarts are
  host-owned. `ircxd` parses policy data and emits client boundary events.
- WebSocket server lifecycle is host-owned. `ircxd` validates IRCv3 WebSocket
  subprotocols and payloads and provides adapter dispatch helpers.
- SNI is implemented as TLS connection option handling, but the IRCv3 index
  currently lists its specification as work-in-progress rather than stable.
- Uncommon vendor numerics may remain raw or generic until encountered and
  intentionally mapped.

## Completion Position

Stable Modern IRC and stable IRCv3 protocol support have no queued core
implementation slice in `docs/stable_spec_matrix.md`.

The broader original wording of "all IRCv3 specs" is not claimed complete
because draft and work-in-progress IRCv3 specifications can change and were
explicitly deprioritized. Existing draft helpers remain tested, but new draft
expansion should start only after an explicit scope change.
