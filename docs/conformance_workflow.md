# Conformance Workflow

This project uses a spec-matrix-first workflow for Modern IRC and stable IRCv3
coverage. The goal is to avoid rediscovering one CAP edge case or one ISUPPORT
token at a time after implementation has already started.

## Workflow

1. Classify the spec item in `docs/stable_spec_matrix.md` before changing
   protocol code.
2. Add or update the expected test cases for the whole grouped spec slice.
   Prefer table-driven tests for token registries such as ISUPPORT and compact
   state-transition tests for CAP lifecycle behavior.
3. Implement the smallest protocol change that satisfies the grouped tests.
4. Add real-server coverage only where scripted tests cannot prove the
   behavior, or where the feature depends on server negotiation.
5. Update the evidence column in `docs/stable_spec_matrix.md` and the broader
   checklist in `docs/completion_audit.md`.
6. Run `scripts/run_verification_gates.sh` before committing.

## Grouping Rules

- CAP work should be grouped by lifecycle behavior: discovery, request, ACK,
  NAK, LIST, NEW, DEL, registration gating, and post-registration host requests.
- ISUPPORT work should be grouped by registry surface: token parsing, typed
  value readers, mode classification, target limits, channel identity, and
  casemapping.
- Modern IRC numerics should be grouped by command family or registration
  lifecycle.
- Host-owned behavior should be documented as an event, callback, adapter, or
  boundary instead of implemented inside the core client process.
- Draft and work-in-progress IRCv3 specs stay out of the stable queue unless
  scope is explicitly changed.

## Evidence Standard

A stable matrix row should not move to `covered` or `host` without concrete
evidence:

- `covered` needs automated tests and the implementation artifact.
- `host` needs parser/event/adapter tests plus a boundary document explaining
  what the embedding application owns.
- Real-server scripts are required when scripted tests would only prove local
  assumptions about negotiation or server-emitted numerics.

The default expectation is that a commit handles one coherent spec slice, not a
single incidental token, unless the change is a regression fix.
