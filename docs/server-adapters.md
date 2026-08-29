# Server adapters

`Ircxd.Server.Adapter` is the integration boundary between the IRC protocol
engine and an embedding application. Use it to project accepted IRC activity,
answer application queries, maintain channel metadata and account roles, check
policy, authenticate accounts, or implement application-specific IRC commands.

The server still owns the live protocol state required to operate sockets:
connections, negotiated capabilities, transient channel modes, live routing,
invites, monitors, and IRC numerics. An adapter owns the application's view and
policy. This separation lets an adapter use ETS, Mnesia, Ecto, or another store
without teaching that store how to parse or render IRC.

For integrations that consume events from an outbound `Ircxd.Client`
connection, use the matching `Ircxd.Client.Adapter` contract described in
`docs/client-adapters.md`.

## Using the ETS adapter

`Ircxd.Server.Adapters.ETS` is the built-in supported adapter:

```elixir
children = [
  {Ircxd.Server,
   id: :public_irc,
   port: 6667,
   server_name: "irc.example.test",
   adapter: {Ircxd.Server.Adapters.ETS, history_limit: 1_000}}
]
```

See `Ircxd.Server.start_link/1` for all server options. See
`Ircxd.Server.Adapters.ETS` for its adapter options.

Each server gets private, isolated ETS tables. They project registered
sessions, channels, memberships, topics, account ACLs, and accepted messages.
An empty channel remains in the adapter's catalog even after the protocol
engine removes its last live membership.

The ETS adapter is suitable for tests and for production applications whose
memory-only state is ephemeral or rebuilt from another source. It has no disk
durability: its data disappears when the adapter/server terminates or its
Erlang node stops. Choose a custom Mnesia or database adapter when restart or
cross-node recovery is required.

### Application queries and operations

Applications do not need an IRC client connection to inspect server state:

```elixir
{:ok, users} = Ircxd.Server.query(server, :users)
{:ok, channels} = Ircxd.Server.query(server, :channels)
{:ok, channel} = Ircxd.Server.query(server, {:channel, "#elixir"})
{:ok, channels} = Ircxd.Server.query(server, {:channels_for, "alice"})
{:ok, messages} = Ircxd.Server.query(server, {:messages, "#elixir", limit: 50})
{:ok, roles} = Ircxd.Server.query(server, {:channel_roles, "#elixir", "account-1"})
```

The ETS adapter supports these operations:

```elixir
{:ok, channel} =
  Ircxd.Server.execute(server, {
    :put_channel,
    "#elixir",
    %{description: "Elixir discussion", topic: "Be kind"}
  })

{:ok, :ok} =
  Ircxd.Server.execute(server, {
    :put_channel_roles,
    "#elixir",
    "account-1",
    [:owner, :moderator]
  })
```

Recognized roles are `:owner`, `:admin`, `:moderator`, `:member`, and
`:banned`. They are application/account roles, distinct from transient IRC
session modes such as `+o` and `+v`. The ETS policy denies JOIN when the
authenticated account has `:banned`; applications can give the other roles
their own meaning in a custom adapter or custom command. Updating an ACL does
not silently change a connected session's IRC modes.

To use account roles during SASL, provide a three-argument verifier. It receives
the username, password, and authentication metadata and returns `{:ok,
account}` or `{:error, reason}`:

```elixir
verify = fn username, password, metadata ->
  MyApp.Accounts.verify_irc_login(username, password, metadata)
end

adapter = {Ircxd.Server.Adapters.ETS, authenticate: verify}
```

Do not retain or log the supplied password. Authentication is disabled for the
ETS adapter when no verifier is configured.

## Implementing an adapter

An adapter must implement `c:Ircxd.Server.Adapter.init/1`. Every other callback
is optional:

```elixir
defmodule MyApp.IrcAdapter do
  @behaviour Ircxd.Server.Adapter

  @impl true
  def init(repo), do: {:ok, repo}

  @impl true
  def handle_event(%Ircxd.Server.Event{type: :message_accepted} = event, context, repo) do
    MyApp.Messages.store_irc_event(repo, event, context)
    {:ok, repo}
  end

  @impl true
  def handle_query({:channel_description, channel}, _context, repo) do
    case MyApp.Channels.fetch(repo, channel) do
      {:ok, record} -> {:ok, record.description, repo}
      :error -> {:error, :not_found, repo}
    end
  end

  @impl true
  def handle_operation({:set_description, channel, text}, context, repo) do
    case MyApp.Channels.set_description(repo, channel, text, context) do
      {:ok, record} -> {:ok, record, repo}
      {:error, reason} -> {:error, reason, repo}
    end
  end
end
```

The callback contract is:

| Callback | Purpose | Return |
| --- | --- | --- |
| `c:Ircxd.Server.Adapter.init/1` | Open or identify application resources. | `{:ok, state}` or `{:error, reason}` |
| `c:Ircxd.Server.Adapter.handle_event/3` | Consume an accepted domain event. | `{:ok, state}` |
| `c:Ircxd.Server.Adapter.handle_query/3` | Answer `Ircxd.Server.query/2`. | `{:ok, value, state}` or `{:error, reason, state}` |
| `c:Ircxd.Server.Adapter.handle_operation/3` | Execute `Ircxd.Server.execute/2`. | `{:ok, value, state}` or `{:error, reason, state}` |
| `c:Ircxd.Server.Adapter.authorize/3` | Allow or reject a protocol action. | `{:ok, state}` or `{:error, reason, state}` |
| `c:Ircxd.Server.Adapter.handle_command/3` | Handle an unknown IRC command. | `{:unhandled, state}`, `{:reply, messages, state}`, or `{:error, reason, state}` |
| `c:Ircxd.Server.Adapter.authenticate/4` | Verify SASL credentials and resolve an account. | `{:ok, account, state}` or `{:error, reason, state}` |
| `c:Ircxd.Server.Adapter.authentication_enabled?/1` | Report whether authentication is enabled. | boolean |
| `c:Ircxd.Server.Adapter.handle_publish/3` | Observe the legacy outbound-message stream. | `{:ok, state}` |

`context` always includes `:server_id` and `:server_name`. Policy and command
contexts also include `:connection` and an `:actor` map containing the known
`:nick`, `:username`, `:realname`, and `:account`. Policy contexts additionally
include `:action`.

`c:Ircxd.Server.Adapter.authorize/3` is called for `{:join, channel}` and
`{:set_topic, channel}`. A rejection produces the applicable IRC error. The
server does not commit the state change. Core IRC commands cannot be overridden
by `c:Ircxd.Server.Adapter.handle_command/3`. That callback runs only after
built-in command matching. Reply messages without a source receive the
configured server name.

## Committed events

`c:Ircxd.Server.Adapter.handle_event/3` receives an `Ircxd.Server.Event` with
`:type`, `:server_id`, `:server_name`, UTC `:at`, and type-specific `:data`:

| Type | Important data |
| --- | --- |
| `:session_registered` | `id`, `nick`, `username`, `realname`, `account`, `registered_at` |
| `:session_nick_changed` | `id`, `nick` |
| `:session_account_changed` | `id`, `account` |
| `:session_disconnected` | `id`, `nick`, `account`, `channels` |
| `:channel_joined` | `channel`, `session_id`, `nick`, `account`, `operator?` |
| `:channel_parted` | `channel`, `session_id`, `nick`, `reason`, and optional `kicked_by` |
| `:channel_topic_changed` | `channel`, `topic`, `actor_id`, `actor` |
| `:message_accepted` | normalized message, sender, target, recipients, and timestamp |

Events represent accepted changes, not raw socket input, and never contain
authentication passwords. `c:Ircxd.Server.Adapter.handle_publish/3` remains
available for applications that must observe all outbound IRC messages,
including numerics. New persistence integrations should use committed events.

WHOIS channel reporting asks the adapter for `{:channels_for, nick}` and falls
back to live protocol state if that query is unsupported or fails. The other
protocol queries continue to use the server's live state; adapter queries are
the explicit application API, not a promise that every IRC LIST/NAMES/WHO read
is database-backed.

## Ordering, failure, and performance

Event, query, operation, policy, command, and publication callbacks share one
serialized state lane. Events and publication are asynchronous casts; queries,
operations, policy checks, and custom commands are synchronous. Calls sent by
the server to its adapter worker keep Erlang sender ordering, so an application
query processed after an accepted server command sees that command's earlier
events.

Authentication runs in a bounded supervised task and uses a separate
serialized authentication-state lane. This prevents a slow authentication
result from overwriting newer event or operation state. Both lanes may safely
hold references to the same external resources or ETS tables, but updates to
the callback state term itself are lane-local. Configure the task limit with
`authentication_timeout` (five seconds by default).

Callback exceptions and invalid returns are contained. Failed asynchronous
event/publication callbacks retain the prior callback state and are not retried;
they are not a durable queue. Synchronous failures become adapter errors. Keep
policy, command, query, and operation callbacks fast because the protocol
server waits for them. Keep event consumers fast enough to avoid an increasing
adapter mailbox. Use a durable application outbox or supervised worker when
delivery guarantees, retries, or slow side effects are required.

For database adapters, make each operation transactional and make event
projection idempotent if the application adds retries. Store stable account and
channel identifiers rather than connection PIDs. Shut down database resources
under the application's own supervision tree.

## Mnesia or Ecto adapters

A Mnesia implementation can keep the same behavior while defining application
owned tables for channel metadata, account ACLs, and messages. The embedding
application must decide schema creation, `disc_copies` versus `ram_copies`, node
membership, migrations, and recovery; ircxd does not make those cluster-wide
choices automatically.

An Ecto adapter should receive a repository or context module from
`c:Ircxd.Server.Adapter.init/1`. Use transactions in
`c:Ircxd.Server.Adapter.handle_operation/3`. Query through application contexts
in `c:Ircxd.Server.Adapter.handle_query/3`. Resolve credentials in
`c:Ircxd.Server.Adapter.authenticate/4`. Do not put a database transaction or
connection process under the IRC connection lifecycle. Supervise it as normal
application infrastructure.

The reusable adapter checks in `test/support/server_adapter_case.ex` exercise
basic channel/role operations and instance isolation. The built-in ETS adapter
uses that same contract suite in ircxd's tests.
