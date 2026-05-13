# STS Boundary Guide

`ircxd` parses IRCv3 Strict Transport Security policies and emits events. It
does not persist policies across application restarts or automatically rewrite
future connection options. Those decisions belong to the embedding app because
they depend on its network list, storage model, and security policy.

## Events

When a server advertises `sts`, `ircxd` emits one of these events:

```elixir
{:sts_policy,
 %{host: host, tls?: false, type: :upgrade, port: 6697, tokens: tokens}}

{:sts_policy,
 %{host: host, tls?: true, type: :persistence, duration: seconds, preload?: false, tokens: tokens}}

{:sts_policy_error,
 %{host: host, value: raw_value, reason: :invalid_sts_policy}}
```

`ircxd` intentionally does not request the `sts` capability. STS is advertised
through `CAP LS`, and `CAP DEL sts` is ignored because policy deletion is not
part of the STS model.

## Persistence

The embedding app can store persistence policies from TLS connections:

```elixir
def handle_event({:sts_policy, %{type: :persistence} = policy}, state) do
  expires_at = DateTime.add(DateTime.utc_now(), policy.duration, :second)

  save_sts_policy(%{
    host: policy.host,
    expires_at: expires_at,
    preload?: policy.preload?,
    tokens: policy.tokens
  })

  {:ok, state}
end
```

For insecure connections, an upgrade policy should be treated as a signal to
reconnect securely on the advertised port:

```elixir
def handle_event({:sts_policy, %{type: :upgrade} = policy}, state) do
  schedule_secure_reconnect(policy.host, policy.port)
  {:ok, state}
end
```

## Applying Stored Policies

Before starting an IRC client, the app can check stored STS state:

```elixir
opts =
  case lookup_valid_sts_policy("irc.example.test") do
    nil ->
      [host: "irc.example.test", port: 6667, tls: false]

    policy ->
      [host: "irc.example.test", port: policy.port || 6697, tls: true]
  end

{:ok, client} =
  opts
  |> Keyword.merge(nick: "myapp", handler: {MyApp.IrcHandler, MyApp.Repo})
  |> Ircxd.start_link()
```

The app should expire stored policies according to `duration`, apply its own
certificate validation settings, and decide how to handle failed secure
reconnects. `ircxd` keeps this outside core so it does not impose a database,
clock, retry, or trust-store model.
