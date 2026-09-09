# Embedded IRC server example

This small OTP application supervises an `Ircxd.Server`, keeps its runtime
configuration in `config/runtime.exs`, and uses the built-in ETS adapter so
application code can query IRC users and channels.

From this directory:

```bash
mix test
IRC_PORT=6667 mix run --no-halt
```

In another terminal, connect a standard IRC client:

```bash
irssi --connect=127.0.0.1 --port=6667 --nick=alice
```

Then run `/join #lobby`. Start a second client as another nickname and join the
same channel to test messaging.

The example uses `{:ircxd, path: "../.."}` so it tests the current checkout. In
an independent application, use the published dependency instead:

```elixir
{:ircxd, "~> 1.2"}
```
