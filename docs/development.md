# Development

Development expects Elixir 1.19 and Erlang/OTP. The opt-in integration checks
also use InspIRCd on `127.0.0.1:6667` and, depending on the check,
`atheme-services`, `irssi`, `tmux`, and `sudo`.

## Setup

Fetch dependencies and generate the local TLS fixtures. Fixture generation
requires `openssl` and only needs to run once after checkout:

```bash
mix deps.get
bin/setup-tests
```

Run the standard project checks:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix hex.build --unpack
```

## Testing

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

The benchmark uses only the Erlang/Elixir runtime and reports median and p95
sample time plus operations per second. Compare results on the same machine
and runtime; it is intended for detecting relative regressions rather than
publishing cross-machine absolute numbers.

## Integration and release checks

Run the full standard verification gate when the local IRC services are
available:

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
