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
   starting/stopping one server and two isolated server instances.
2. [x] Add a TCP listener/acceptor boundary with tests using an ephemeral port,
   clean shutdown, and port-bind failure behavior.
3. [ ] Implement per-connection registration (`NICK`, `USER`, `PASS`, `CAP`)
   and test the complete handshake through `Ircxd.Client`.
4. [ ] Implement identity and channel state with tests for `JOIN`, `PART`,
   `PRIVMSG`, `NOTICE`, `TOPIC`, `NAMES`, `PING`, and `QUIT`.
5. [ ] Implement server-to-client event fan-out and isolation tests proving
   clients on different server instances cannot observe one another. Initial
   same-channel `PRIVMSG` fan-out is covered.
6. [x] Add a configurable subscriber callback and test that published messages
   reach the embedding application with connection metadata.
7. [ ] Add configurable callbacks/handler hooks and test callback failures and
   connection cleanup without taking down the listener.
8. [x] Add an authentication contract for SASL and test database-backed host
   callbacks, success, failure, and account metadata without embedding a DB.
9. [ ] Add protocol limits and malformed-input tests, including line size,
   registration timeouts, unknown commands, and nick/channel validation.
10. [ ] Run the full ExUnit suite, then run an irssi manual/integration check;
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
| 2026-07-29 | Added first channel/message fan-out slice; two `Ircxd.Client` clients receive `PRIVMSG` | `test/ircxd/server_messaging_test.exs` |
