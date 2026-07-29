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

1. [ ] Define the public server lifecycle API and child spec with tests for
   starting/stopping one server and two isolated server instances.
2. [ ] Add a TCP listener/acceptor boundary with tests using an ephemeral port,
   clean shutdown, and port-bind failure behavior.
3. [ ] Implement per-connection registration (`NICK`, `USER`, `PASS`, `CAP`)
   and test the complete handshake through `Ircxd.Client`.
4. [ ] Implement identity and channel state with tests for `JOIN`, `PART`,
   `PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `PING`, and `QUIT`.
5. [ ] Implement server-to-client event fan-out and isolation tests proving
   clients on different server instances cannot observe one another.
6. [ ] Add configurable callbacks/handler hooks and test callback failures and
   connection cleanup without taking down the listener.
7. [ ] Add protocol limits and malformed-input tests, including line size,
   registration timeouts, unknown commands, and nick/channel validation.
8. [ ] Run the full ExUnit suite, then run an irssi manual/integration check;
   document supported behavior and known boundaries.
9. [ ] Commit each coherent TDD slice with a detailed rationale and push every
   commit to the configured remote.

## Progress log

| Date | Change | Evidence |
|---|---|---|
| 2026-07-29 | Plan created on `server`; implementation not started | `plans/server.md` |

