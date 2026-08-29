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

## Versioning and release tags

The package version follows [Semantic Versioning](https://semver.org/). Choose
the increment based on the public API change, then update `mix.exs` with:

```bash
bin/bump-version <major|minor|patch>
```

- `major` is for incompatible public API changes.
- `minor` is for backward-compatible functionality.
- `patch` is for backward-compatible fixes.

For versions below `1.0.0`, Hex recommends using a minor increment for breaking
changes. The package version remains plain `MAJOR.MINOR.PATCH`, as required by
Hex. After committing the version change and completing the release checks,
create its local Git tag with:

```bash
bin/release
```

The release script reads the version from `mix.exs`, creates the corresponding
`vMAJOR.MINOR.PATCH` tag, and refuses to replace an existing local or remote
tag. The `v` prefix follows the Git-tag example in the SemVer specification;
it is not part of the Hex package version. The script does not publish the
package or push the tag. Do those explicitly after reviewing the release:

```bash
mix hex.publish
git push origin vMAJOR.MINOR.PATCH
```
