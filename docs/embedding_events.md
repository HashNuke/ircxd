# Embedding Event Handling

`ircxd` emits protocol events and leaves application effects to the embedding
app. This is the boundary for message storage, unread state, mention
notifications, Phoenix broadcasts, and metrics.

## Delivery Options

For direct process messages:

```elixir
{:ok, client} =
  Ircxd.start_link(
    host: "irc.example.test",
    port: 6697,
    tls: true,
    nick: "myapp",
    notify: self()
  )

receive do
  {:ircxd, {:privmsg, payload}} -> persist_message(payload)
end
```

For stateful callbacks:

```elixir
defmodule MyApp.IrcHandler do
  @behaviour Ircxd.Handler

  @impl true
  def init(repo), do: {:ok, %{repo: repo}}

  @impl true
  def handle_event({:privmsg, payload}, state) do
    persist_message(state.repo, payload)
    {:ok, state}
  end

  def handle_event({:standard_reply, payload}, state) do
    log_standard_reply(payload)
    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}
end
```

Then pass the handler when starting the client:

```elixir
{:ok, client} =
  Ircxd.start_link(
    host: "irc.example.test",
    nick: "myapp",
    handler: {MyApp.IrcHandler, MyApp.Repo}
  )
```

## Persistence Boundary

The handler receives decoded protocol events, not database-specific commands.
The embedding app decides:

- Which events become persisted messages.
- Retention windows and pruning.
- Channel/server/user schema design.
- Mention detection and notification policy.
- Broadcast fanout to Phoenix Channels, LiveView, or another UI layer.

`ircxd` should not depend on Ecto, Phoenix PubSub, browser notifications, or a
specific application database.
