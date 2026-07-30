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

TLS clients verify the server certificate chain and hostname by default using
the operating-system CA store. A custom trust root can be supplied with
`tls_options: [cacertfile: "/path/to/ca.pem"]`. Disabling verification with
`verify: :verify_none` should be limited to isolated development fixtures.

## Embedded IRC Server

Applications can start one or more independent IRC servers in their own
supervision tree. Give each server child a distinct `:id`:

```elixir
children = [
  {Ircxd.Server, id: :public_irc, port: 6667, server_name: "public.example"},
  {Ircxd.Server, id: :internal_irc, port: 6668, server_name: "internal.example"}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The server accepts one `adapter: {Module, init_arg}` for application-owned
message persistence, side effects, and SASL credential checks. See
`docs/server_ircv3_matrix.md` and `plans/server.md` for the current protocol
coverage and boundaries.

Adapters implement `Ircxd.Server.Adapter`. The callback state is shared by a
serialized worker, so message and authentication callbacks can coordinate
application-owned state such as authentication attempt tracking. Each
published message includes server and connection metadata:

```elixir
defmodule MyApp.IrcAdapter do
  @behaviour Ircxd.Server.Adapter

  @impl true
  def init(db), do: {:ok, db}

  @impl true
  def handle_publish(message, metadata, db) do
    MyApp.Messages.persist(db, message, metadata)
    {:ok, db}
  end
end

{Ircxd.Server,
 id: :public_irc,
 port: 6667,
 adapter: {MyApp.IrcAdapter, MyApp.Repo}}
```

Adapters may implement `handle_publish/3` and `authenticate/4`; both callbacks
return updated adapter state. Authentication callbacks return
`{:ok, account, state}` or `{:error, reason, state}`. Callback exceptions are
contained by the worker; persistence and authentication policy remain owned by
the embedding application.

Server information can be configured with `motd: ["Welcome"]`,
`info: ["Ircxd.Server"]`, and `isupport: ["CHANTYPES=#&", "NICKLEN=30"]`.
Help text uses `help: %{"JOIN" => ["JOIN <channel>"]}`. Administrative
details use `admin: %{location: ["Operations"], email: "admin@example.test"}`.
Network protection defaults to 1,024 simultaneous connections, 100 commands
per connection per second, 128 concurrent TLS handshakes, and a five-second TLS
handshake timeout. These can be changed with `max_connections`,
`command_rate_limit`, `max_handshakes`, and `handshake_timeout`.

Authentication callbacks run in a supervised, serialized worker with a
five-second timeout. Configure this per server with
`authentication_timeout`; application configuration under
`config :ircxd, Ircxd.Server, ...` supplies defaults when per-server options
are not provided.

For an implicit TLS listener, set `tls: true` and provide standard Erlang SSL
options such as `certfile` and `keyfile` through `tls_options`:

```elixir
{Ircxd.Server,
 id: :secure_irc,
 port: 6697,
 tls: true,
 tls_options: [certfile: "/path/to/server.crt", keyfile: "/path/to/server.key"]}
```

SASL EXTERNAL is disabled by default. Enabling it requires a TLS listener that
verifies client certificates:

```elixir
{Ircxd.Server,
 port: 6697,
 tls: true,
 external_auth: true,
 adapter: {MyApp.IrcAdapter, MyApp.Repo},
 tls_options: [
   certfile: "/path/to/server.crt",
   keyfile: "/path/to/server.key",
   verify: :verify_peer,
   cacertfile: "/path/to/client-ca.crt"
 ]}
```

The authenticator metadata includes `:mechanism`, `:peer`, `:transport`,
`:peer_certificate`, and `:peer_certificate_sha256`. Applications must map or
authorize the submitted EXTERNAL identity against that verified certificate.

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

Set up the locally generated TLS fixtures once after checking out the
repository. This requires `openssl`:

```bash
bin/setup-tests
```

Run the default automated suite:

```bash
mix test
```

Run the suite with the project coverage floor:

```bash
mix cover
```

Run repeatable microbenchmarks for the protocol hot paths:

```bash
mix bench
```

The benchmark command uses only the Erlang/Elixir runtime and reports median
and p95 sample time plus operations per second. Compare results on the same
machine and runtime; it is intended for detecting relative regressions rather
than publishing cross-machine absolute numbers.

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
scripts/run_irssi_server_check.sh
```

## Documentation

- `docs/spec_audit.md`: detailed protocol implementation evidence.
- `docs/stable_spec_matrix.md`: stable Modern IRC and IRCv3 coverage matrix.
- `docs/ircv3_index_audit.md`: stable versus draft/WIP IRCv3 classification.
- `docs/modern_irc_audit.md`: Modern IRC source audit.
- `docs/security.md`: security review, findings, and remediation priorities.
- `docs/conformance_workflow.md`: workflow for changing spec coverage.
- `docs/completion_audit.md`: requirement-to-artifact checklist and gates.
- `docs/specs.md`: source specification links.

## Development

Development expects Elixir 1.19, Erlang/OTP, InspIRCd on `127.0.0.1:6667`,
and optional `atheme-services`, `irssi`, `tmux`, and `sudo` for the opt-in
integration checks.

Run `bin/setup-tests` once after checkout to generate the TLS fixtures used by
the TLS integration tests.

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
