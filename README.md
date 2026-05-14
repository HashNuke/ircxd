# ircxd

`ircxd` is an Elixir IRC client library for applications that need to connect
to IRC networks, negotiate Modern IRC / IRCv3 capabilities, and handle IRC
events without taking ownership of application storage or UI policy.

It is intended to be embedded in Phoenix apps, background workers, bots,
bridges, notification systems, and other Elixir applications.

## Features

- Modern IRC message parsing, serialization, size validation, and source mask
  parsing.
- TCP and implicit TLS connections, including SNI configuration.
- IRC registration with `PASS`, `NICK`, `USER`, `CAP LS 302`, automatic
  `PING`/`PONG`, reconnect support, and nickname-collision retry handling.
- IRCv3 capability negotiation, message tags, server-time, message IDs,
  echo-message, labeled responses, batches, standard replies, account tracking,
  away notifications, monitor, UTF8ONLY, WebIRC, and WebSocket protocol helpers.
- SASL `PLAIN`, `EXTERNAL`, and `SCRAM-SHA-256` helpers with fallback and
  failure-policy support.
- Modern IRC command helpers for channel operations, user/server queries,
  messaging, service queries, modes, and raw commands.
- CTCP helpers and DCC CTCP payload parsing/encoding. Direct DCC socket and file
  transfer policy remains host-owned.
- Callback-style event delivery through `:notify` or `Ircxd.Handler`.
- Host-owned boundaries for storage, scrollback, notifications, WebSocket
  server adapters, STS persistence, and DCC transfer policy.
- Automated unit tests, scripted IRC server tests, local InspIRCd integration,
  services-backed IRCv3 integration, and an optional irssi cross-client check.

For the detailed implementation matrix and spec evidence, see
`docs/spec_audit.md`, `docs/stable_spec_matrix.md`, and
`docs/completion_audit.md`.

## Installation

Add `ircxd` to your Mix dependencies:

```elixir
def deps do
  [
    {:ircxd, "~> 1.0"}
  ]
end
```

Until the package is published, depend on the repository directly:

```elixir
def deps do
  [
    {:ircxd, git: "https://github.com/HashNuke/ircxd.git"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quickstart

Start a client process and receive events in the calling process:

```elixir
{:ok, client} =
  Ircxd.start_link(
    host: "irc.libera.chat",
    port: 6697,
    tls: true,
    sni: "irc.libera.chat",
    nick: "myapp",
    username: "myapp",
    realname: "My App",
    caps: ["server-time", "echo-message"],
    notify: self()
  )

receive do
  {:ircxd, :registered} -> :ok
end

:ok = Ircxd.Client.join(client, "#elixir")
:ok = Ircxd.Client.privmsg(client, "#elixir", "hello from ircxd")
```

Use `Ircxd.Handler` when you want callback-style event handling:

```elixir
defmodule MyApp.IrcHandler do
  use Ircxd.Handler

  @impl true
  def handle_event(:registered, _payload, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(:message, message, state) do
    # Store, notify, broadcast, or ignore from your host application.
    {:ok, state}
  end
end
```

## Application Boundaries

`ircxd` does not store messages, own scrollback, send browser notifications, or
manage user accounts. It emits IRC events and provides protocol helpers; the
embedding application decides what to persist, how long to keep it, and how to
present it.

WebSocket server lifecycle is also host-owned. `Ircxd.WebSocket` validates the
IRCv3 WebSocket subprotocol and one-line payload rules, and host applications
can provide adapters implementing `Ircxd.WebSocket.Adapter` for Phoenix
Channels, Cowboy, Bandit, or another stack.

More boundary guidance is available in:

- `docs/host_boundaries.md`
- `docs/embedding_events.md`
- `docs/dcc_boundaries.md`
- `docs/sts_boundaries.md`
- `docs/websocket_adapters.md`

## Testing

Run the default automated suite:

```bash
mix test
```

Run the full standard verification gate:

```bash
scripts/run_verification_gates.sh
```

Include the optional irssi cross-client check:

```bash
IRCXD_INCLUDE_IRSSI=1 scripts/run_verification_gates.sh
```

The integration tests expect a local InspIRCd on `127.0.0.1:6667`. Additional
opt-in scripts create disposable local fixtures for services-backed IRCv3 and
real standard-replies coverage:

```bash
scripts/run_services_integration.sh
scripts/run_standard_replies_integration.sh
scripts/run_irssi_manual_check.sh
```

## Documentation

- `docs/spec_audit.md`: detailed protocol implementation evidence.
- `docs/stable_spec_matrix.md`: stable Modern IRC and IRCv3 coverage matrix.
- `docs/ircv3_index_audit.md`: stable versus draft/WIP IRCv3 classification.
- `docs/modern_irc_audit.md`: Modern IRC source audit.
- `docs/conformance_workflow.md`: workflow for changing spec coverage.
- `docs/completion_audit.md`: requirement-to-artifact checklist and gates.
- `docs/specs.md`: source specification links.

## Development

Development expects Elixir 1.19, Erlang/OTP, InspIRCd on `127.0.0.1:6667`,
and optional `atheme-services`, `irssi`, `tmux`, and `sudo` for the opt-in
integration checks.

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix hex.build --unpack
```

Use `scripts/run_verification_gates.sh` when the local IRC services are
available and you want the same gate used before release-oriented commits.

## License

Copyright 2026 Akash Manohar John.

Licensed under the Apache License, Version 2.0. See `LICENSE`.
