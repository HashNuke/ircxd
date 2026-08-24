defmodule Ircxd.Server.Adapters.ETS do
  @moduledoc """
  Supported in-memory `Ircxd.Server.Adapter` backed by private ETS tables.

  Each adapter instance owns isolated tables for sessions, channels,
  memberships, and accepted messages. The adapter is suitable for tests and
  for production servers whose state may be rebuilt after a node restart. ETS
  does not provide disk durability.
  """

  @behaviour Ircxd.Server.Adapter

  alias Ircxd.Server.Event

  @impl true
  def init(opts) do
    tables = %{
      sessions: new_table(:sessions, :set),
      channels: new_table(:channels, :set),
      memberships: new_table(:memberships, :set),
      messages: new_table(:messages, :ordered_set)
    }

    {:ok,
     %{
       tables: tables,
       authenticator: Keyword.get(opts, :authenticate),
       history_limit: normalize_history_limit(Keyword.get(opts, :history_limit, 1_000)),
       message_sequence: 0
     }}
  end

  @impl true
  def handle_event(%Event{type: :session_registered, data: session}, _context, state) do
    :ets.insert(state.tables.sessions, {session.id, session})
    {:ok, state}
  end

  def handle_event(%Event{type: :session_nick_changed, data: data}, _context, state) do
    state.tables.memberships
    |> :ets.tab2list()
    |> Enum.each(fn
      {{_channel, id} = key, membership} when id == data.id ->
        :ets.insert(state.tables.memberships, {key, %{membership | nick: data.nick}})

      _other ->
        :ok
    end)

    update_session(state, data.id, &Map.put(&1, :nick, data.nick))
  end

  def handle_event(%Event{type: :session_account_changed, data: data}, _context, state) do
    update_session(state, data.id, &Map.put(&1, :account, data.account))
  end

  def handle_event(%Event{type: :session_disconnected, data: %{id: id}}, _context, state) do
    :ets.delete(state.tables.sessions, id)

    state.tables.memberships
    |> :ets.tab2list()
    |> Enum.each(fn
      {{_channel, ^id} = key, _membership} -> :ets.delete(state.tables.memberships, key)
      _other -> :ok
    end)

    {:ok, state}
  end

  def handle_event(%Event{type: :channel_joined, data: data}, _context, state) do
    ensure_channel(state, data.channel)

    :ets.insert(
      state.tables.memberships,
      {{data.channel, data.session_id},
       %{nick: data.nick, operator?: data.operator?, voice?: false}}
    )

    {:ok, state}
  end

  def handle_event(%Event{type: :channel_parted, data: data}, _context, state) do
    :ets.delete(state.tables.memberships, {data.channel, data.session_id})
    {:ok, state}
  end

  def handle_event(%Event{type: :channel_topic_changed, data: data}, _context, state) do
    channel = ensure_channel(state, data.channel)
    :ets.insert(state.tables.channels, {data.channel, %{channel | topic: data.topic}})
    {:ok, state}
  end

  def handle_event(%Event{type: :message_accepted, data: data}, _context, state) do
    sequence = state.message_sequence + 1

    record = %{
      id: sequence,
      command: data.message.command,
      from: data.from,
      target: data.target,
      body: List.last(data.message.params),
      tags: data.message.tags,
      at: data.at
    }

    :ets.insert(state.tables.messages, {sequence, record})
    trim_messages(state.tables.messages, state.history_limit)
    {:ok, %{state | message_sequence: sequence}}
  end

  def handle_event(%Event{}, _context, state), do: {:ok, state}

  @impl true
  def handle_query(:users, _context, state) do
    users =
      state.tables.sessions
      |> :ets.tab2list()
      |> Enum.map(fn {_id, session} -> session end)
      |> Enum.sort_by(&String.downcase(&1.nick))

    {:ok, users, state}
  end

  def handle_query({:channel, name}, _context, state) when is_binary(name) do
    case :ets.lookup(state.tables.channels, name) do
      [{^name, channel}] ->
        {:ok, Map.put(channel, :members, member_nicks(state, name)), state}

      [] ->
        {:error, :not_found, state}
    end
  end

  def handle_query(:channels, _context, state) do
    channels =
      state.tables.channels
      |> :ets.tab2list()
      |> Enum.map(fn {name, channel} -> Map.put(channel, :members, member_nicks(state, name)) end)
      |> Enum.sort_by(&String.downcase(&1.name))

    {:ok, channels, state}
  end

  def handle_query({:channels_for, nick}, _context, state) when is_binary(nick) do
    channels =
      state.tables.memberships
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{channel, _session_id}, %{nick: member_nick}} ->
          if String.downcase(member_nick) == String.downcase(nick), do: [channel], else: []
      end)
      |> Enum.sort()

    {:ok, channels, state}
  end

  def handle_query({:channel_roles, channel, account}, _context, state)
      when is_binary(channel) and is_binary(account) do
    {:ok, channel_roles(state, channel, account), state}
  end

  def handle_query({:messages, target, opts}, _context, state)
      when is_binary(target) and is_list(opts) do
    limit = normalize_query_limit(Keyword.get(opts, :limit, 50))

    messages =
      state.tables.messages
      |> :ets.tab2list()
      |> Enum.map(fn {_id, message} -> message end)
      |> Enum.filter(&(&1.target == target))
      |> Enum.take(-limit)

    {:ok, messages, state}
  end

  def handle_query(_query, _context, state), do: {:error, :unsupported_query, state}

  @impl true
  def handle_operation({:put_channel, name, attrs}, _context, state)
      when is_binary(name) and is_map(attrs) do
    channel =
      state
      |> ensure_channel(name)
      |> Map.merge(Map.take(attrs, [:description, :topic, :modes]))
      |> Map.put(:name, name)

    :ets.insert(state.tables.channels, {name, channel})
    {:ok, Map.put(channel, :members, member_nicks(state, name)), state}
  end

  def handle_operation({:put_channel_roles, channel_name, account, roles}, _context, state)
      when is_binary(channel_name) and is_binary(account) and is_list(roles) do
    channel = ensure_channel(state, channel_name)
    roles = roles |> MapSet.new() |> MapSet.intersection(allowed_roles())
    channel = %{channel | acl: Map.put(channel.acl, account, roles)}
    :ets.insert(state.tables.channels, {channel_name, channel})
    {:ok, :ok, state}
  end

  def handle_operation(_operation, _context, state),
    do: {:error, :unsupported_operation, state}

  @impl true
  def authorize({:join, channel}, context, state) do
    roles = channel_roles(state, channel, get_in(context, [:actor, :account]))

    if MapSet.member?(roles, :banned),
      do: {:error, :banned, state},
      else: {:ok, state}
  end

  def authorize(_action, _context, state), do: {:ok, state}

  @impl true
  def authenticate(username, password, metadata, %{authenticator: authenticator} = state)
      when is_function(authenticator, 3) do
    case authenticator.(username, password, metadata) do
      {:ok, account} -> {:ok, account, state}
      {:error, reason} -> {:error, reason, state}
      _other -> {:error, :invalid_authentication_return, state}
    end
  rescue
    _error -> {:error, :authentication_failed, state}
  catch
    _kind, _reason -> {:error, :authentication_failed, state}
  end

  def authenticate(_username, _password, _metadata, state),
    do: {:error, :authentication_not_configured, state}

  @impl true
  def authentication_enabled?(state), do: is_function(state.authenticator, 3)

  defp new_table(label, type) do
    :ets.new(label, [type, :private, read_concurrency: true, write_concurrency: true])
  end

  defp ensure_channel(state, name) do
    case :ets.lookup(state.tables.channels, name) do
      [{^name, channel}] ->
        channel

      [] ->
        channel = %{name: name, topic: nil, description: nil, modes: MapSet.new(), acl: %{}}
        :ets.insert(state.tables.channels, {name, channel})
        channel
    end
  end

  defp update_session(state, id, fun) do
    case :ets.lookup(state.tables.sessions, id) do
      [{^id, session}] ->
        :ets.insert(state.tables.sessions, {id, fun.(session)})
        {:ok, state}

      [] ->
        {:ok, state}
    end
  end

  defp member_nicks(state, channel) do
    state.tables.memberships
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{^channel, _session_id}, %{nick: nick}} -> [nick]
      _other -> []
    end)
    |> Enum.sort_by(&String.downcase/1)
  end

  defp channel_roles(_state, _channel, nil), do: MapSet.new()

  defp channel_roles(state, channel, account) do
    case :ets.lookup(state.tables.channels, channel) do
      [{^channel, channel_record}] -> Map.get(channel_record.acl, account, MapSet.new())
      [] -> MapSet.new()
    end
  end

  defp trim_messages(table, limit) do
    overflow = :ets.info(table, :size) - limit

    if overflow > 0 do
      table
      |> :ets.tab2list()
      |> Enum.take(overflow)
      |> Enum.each(fn {key, _message} -> :ets.delete(table, key) end)
    end
  end

  defp normalize_history_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, 10_000)

  defp normalize_history_limit(_limit), do: 1_000

  defp normalize_query_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, 1_000)

  defp normalize_query_limit(_limit), do: 50

  defp allowed_roles,
    do: MapSet.new([:owner, :admin, :moderator, :member, :banned])
end
