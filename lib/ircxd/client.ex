defmodule Ircxd.Client do
  @moduledoc """
  GenServer IRC client.

  Options:

    * `:host` - IRC server host.
    * `:port` - IRC server port.
    * `:tls` - true for implicit TLS.
    * `:nick` - desired nickname.
    * `:username` - username sent in registration.
    * `:realname` - realname sent in registration.
    * `:caps` - IRCv3 capabilities to request.
    * `:notify` - pid to receive `{:ircxd, event}` messages.
    * `:handler` - `{module, init_arg}` implementing `Ircxd.Handler`.
  """

  use GenServer

  alias Ircxd.Batch
  alias Ircxd.ChatHistory
  alias Ircxd.Metadata
  alias Ircxd.Message
  alias Ircxd.Monitor
  alias Ircxd.Multiline
  alias Ircxd.Names
  alias Ircxd.SASL
  alias Ircxd.Source
  alias Ircxd.ISupport
  alias Ircxd.StandardReply
  alias Ircxd.Tags
  alias Ircxd.WebIRC
  alias Ircxd.Who
  alias Ircxd.Whois

  @tcp_opts [:binary, packet: :line, active: true]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def join(client, channel), do: GenServer.call(client, {:send, "JOIN", [channel]})

  def part(client, channel, reason \\ ""),
    do: GenServer.call(client, {:send, "PART", [channel, reason]})

  def topic(client, channel, topic \\ nil)
  def topic(client, channel, nil), do: GenServer.call(client, {:send, "TOPIC", [channel]})

  def topic(client, channel, topic),
    do: GenServer.call(client, {:send, "TOPIC", [channel, topic]})

  def mode(client, target, modes, params \\ []),
    do: GenServer.call(client, {:send, "MODE", [target, modes | params]})

  def kick(client, channel, nick, reason \\ ""),
    do: GenServer.call(client, {:send, "KICK", [channel, nick, reason]})

  def privmsg(client, target, body),
    do: GenServer.call(client, {:send, "PRIVMSG", [target, body]})

  def privmsg(client, target, body, tags) when is_map(tags),
    do:
      GenServer.call(
        client,
        {:send, %Message{command: "PRIVMSG", params: [target, body], tags: tags}}
      )

  def notice(client, target, body), do: GenServer.call(client, {:send, "NOTICE", [target, body]})

  def notice(client, target, body, tags) when is_map(tags),
    do:
      GenServer.call(
        client,
        {:send, %Message{command: "NOTICE", params: [target, body], tags: tags}}
      )

  def tagmsg(client, target, tags) when is_map(tags),
    do: GenServer.call(client, {:send, %Message{command: "TAGMSG", params: [target], tags: tags}})

  def setname(client, realname), do: GenServer.call(client, {:send, "SETNAME", [realname]})

  def rename(client, old_channel, new_channel, reason \\ nil)

  def rename(client, old_channel, new_channel, nil),
    do: GenServer.call(client, {:send, "RENAME", [old_channel, new_channel]})

  def rename(client, old_channel, new_channel, reason),
    do: GenServer.call(client, {:send, "RENAME", [old_channel, new_channel, reason]})

  def quit(client, reason \\ "leaving"), do: GenServer.call(client, {:send, "QUIT", [reason]})
  def raw(client, command, params \\ []), do: GenServer.call(client, {:send, command, params})
  def who(client, mask, options \\ nil)
  def who(client, mask, nil), do: GenServer.call(client, {:send, "WHO", [mask]})
  def who(client, mask, options), do: GenServer.call(client, {:send, "WHO", [mask, options]})
  def whois(client, nick), do: GenServer.call(client, {:send, "WHOIS", [nick]})
  def whowas(client, nick, count \\ nil)
  def whowas(client, nick, nil), do: GenServer.call(client, {:send, "WHOWAS", [nick]})
  def whowas(client, nick, count), do: GenServer.call(client, {:send, "WHOWAS", [nick, count]})

  def monitor_add(client, targets),
    do: GenServer.call(client, {:send, "MONITOR", ["+", join_targets(targets)]})

  def monitor_remove(client, targets),
    do: GenServer.call(client, {:send, "MONITOR", ["-", join_targets(targets)]})

  def monitor_clear(client), do: GenServer.call(client, {:send, "MONITOR", ["C"]})
  def monitor_list(client), do: GenServer.call(client, {:send, "MONITOR", ["L"]})
  def monitor_status(client), do: GenServer.call(client, {:send, "MONITOR", ["S"]})

  def metadata_get(client, target, keys),
    do: GenServer.call(client, {:send, "METADATA", [target, "GET" | List.wrap(keys)]})

  def metadata_sub(client, keys),
    do: GenServer.call(client, {:send, "METADATA", ["*", "SUB" | List.wrap(keys)]})

  def metadata_unsub(client, keys),
    do: GenServer.call(client, {:send, "METADATA", ["*", "UNSUB" | List.wrap(keys)]})

  def metadata_set(client, target, key, value),
    do: GenServer.call(client, {:send, "METADATA", [target, "SET", key, value]})

  def metadata_clear_key(client, target, key),
    do: GenServer.call(client, {:send, "METADATA", [target, "SET", key]})

  def metadata_sync(client, target),
    do: GenServer.call(client, {:send, "METADATA", [target, "SYNC"]})

  def chathistory_latest(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:latest, target, selector, limit})}
      )

  def chathistory_before(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:before, target, selector, limit})}
      )

  def chathistory_after(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:after, target, selector, limit})}
      )

  def chathistory_around(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:around, target, selector, limit})}
      )

  def chathistory_between(client, target, first_selector, second_selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY",
         ChatHistory.params({:between, target, first_selector, second_selector, limit})}
      )

  def chathistory_targets(client, first_timestamp, second_timestamp, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY",
         ChatHistory.params({:targets, first_timestamp, second_timestamp, limit})}
      )

  def raw_tagged(client, command, params, tags),
    do: GenServer.call(client, {:send, %Message{command: command, params: params, tags: tags}})

  def labeled_raw(client, label, command, params \\ []),
    do: raw_tagged(client, command, params, %{"label" => label})

  def transmit(client, %Message{} = message), do: GenServer.call(client, {:send, message})
  def flush_server_time(client), do: GenServer.call(client, :flush_server_time)

  def multiline_privmsg(client, target, body, opts \\ []) do
    GenServer.call(client, {:send_multiline, "PRIVMSG", target, body, opts})
  end

  def multiline_notice(client, target, body, opts \\ []) do
    GenServer.call(client, {:send_multiline, "NOTICE", target, body, opts})
  end

  @impl true
  def init(opts) do
    state = %{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, if(Keyword.get(opts, :tls, false), do: 6697, else: 6667)),
      tls: Keyword.get(opts, :tls, false),
      nick: Keyword.fetch!(opts, :nick),
      username: Keyword.get(opts, :username, Keyword.fetch!(opts, :nick)),
      realname: Keyword.get(opts, :realname, Keyword.fetch!(opts, :nick)),
      webirc: Keyword.get(opts, :webirc),
      reconnect: normalize_reconnect(Keyword.get(opts, :reconnect, false)),
      reconnect_attempts: 0,
      caps: Keyword.get(opts, :caps, []),
      msgid_dedupe: Keyword.get(opts, :msgid_dedupe, false),
      seen_msgids: MapSet.new(),
      server_time_order: Keyword.get(opts, :server_time_order, false),
      server_time_buffer: [],
      server_time_flush_timer: nil,
      available_caps: %{},
      active_caps: MapSet.new(),
      current_nick: Keyword.fetch!(opts, :nick),
      nick_retry_fun: Keyword.get(opts, :nick_retry_fun, &default_nick_retry/2),
      sasl: Keyword.get(opts, :sasl),
      sasl_mechanisms: normalize_sasl(Keyword.get(opts, :sasl)),
      sasl_index: 0,
      sasl_failure_policy: Keyword.get(opts, :sasl_failure, :continue),
      sasl_in_progress?: false,
      socket: nil,
      transport: nil,
      registered?: false,
      notify: Keyword.get(opts, :notify),
      handler: nil,
      handler_state: nil,
      active_batches: %{},
      multiline_batches: %{},
      labeled_response_batches: %{},
      labeled_requests: %{},
      metadata_batches: %{},
      multiline_ref: 0
    }

    {:ok, state} = init_handler(state, Keyword.get(opts, :handler))
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    with {:ok, transport, socket} <- connect(state) do
      state = %{state | transport: transport, socket: socket}
      maybe_send_webirc(state)
      send_message(state, "CAP", ["LS", "302"])
      send_message(state, "NICK", [state.nick])
      send_message(state, "USER", [state.username, "0", "*", state.realname])
      state = emit(state, {:connected, %{host: state.host, port: state.port, tls: state.tls}})
      {:noreply, state}
    else
      {:error, reason} ->
        _state = emit(state, {:connect_error, reason})
        {:stop, reason, state}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state), do: handle_line(line, state)
  def handle_info({:ssl, socket, line}, %{socket: socket} = state), do: handle_line(line, state)
  def handle_info({:tcp_closed, _socket}, state), do: handle_disconnect(state)
  def handle_info({:ssl_closed, _socket}, state), do: handle_disconnect(state)
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, reason, state}
  def handle_info({:ssl_error, _socket, reason}, state), do: {:stop, reason, state}

  def handle_info(:flush_server_time, state) do
    {:noreply, flush_server_time_buffer(%{state | server_time_flush_timer: nil})}
  end

  @impl true
  def handle_call({:send, %Message{} = message}, _from, state) do
    case send_message(state, message) do
      :ok -> {:reply, :ok, maybe_track_labeled_request(state, message)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:send, command, params}, _from, state) do
    case send_message(state, command, params) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:flush_server_time, _from, state) do
    {:reply, :ok, flush_server_time_buffer(state)}
  end

  def handle_call({:send_multiline, command, target, body, opts}, _from, state) do
    {ref, state} = multiline_ref(state, opts)

    result =
      with :ok <- send_message(state, "BATCH", ["+" <> ref, "draft/multiline", target]),
           :ok <- send_multiline_lines(state, command, target, body, ref) do
        send_message(state, "BATCH", ["-" <> ref])
      end

    case result do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  defp connect(%{tls: true} = state) do
    with {:ok, socket} <-
           :ssl.connect(String.to_charlist(state.host), state.port, @tcp_opts, 10_000) do
      {:ok, :ssl, socket}
    end
  end

  defp connect(state) do
    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(state.host), state.port, @tcp_opts, 10_000) do
      {:ok, :gen_tcp, socket}
    end
  end

  defp maybe_send_webirc(%{webirc: nil}), do: :ok

  defp maybe_send_webirc(%{webirc: webirc} = state) do
    send_message(state, "WEBIRC", WebIRC.params(webirc))
  end

  defp handle_disconnect(state) do
    state = emit(state, :disconnected)

    if reconnect?(state) do
      attempt = state.reconnect_attempts + 1
      delay = state.reconnect.delay
      Process.send_after(self(), :connect, delay)

      state =
        state
        |> emit({:reconnecting, %{attempt: attempt, delay: delay}})
        |> Map.merge(%{
          socket: nil,
          transport: nil,
          registered?: false,
          available_caps: %{},
          active_caps: MapSet.new(),
          active_batches: %{},
          multiline_batches: %{},
          labeled_response_batches: %{},
          labeled_requests: %{},
          metadata_batches: %{},
          seen_msgids: MapSet.new(),
          server_time_buffer: [],
          server_time_flush_timer: nil,
          reconnect_attempts: attempt
        })

      {:noreply, state}
    else
      {:stop, :normal, state}
    end
  end

  defp reconnect?(%{reconnect: nil}), do: false
  defp reconnect?(%{reconnect: %{max_attempts: :infinity}}), do: true

  defp reconnect?(%{reconnect: reconnect, reconnect_attempts: attempts}),
    do: attempts < reconnect.max_attempts

  defp handle_line(line, state) do
    case Message.parse(line) do
      {:ok, %Message{command: "PING", params: [token | _]} = message} ->
        state = emit(state, {:message, message})
        send_message(state, "PONG", [token])
        {:noreply, state}

      {:ok, %Message{command: "CAP", params: [_nick, "LS" | params]} = message} ->
        state = collect_caps(state, List.last(params) || "")
        state = emit(state, {:message, message})

        if cap_list_complete?(message) do
          request_caps_or_end(state)
        else
          {:noreply, state}
        end

      {:ok, %Message{command: "CAP", params: [_nick, "ACK", caps]} = message} ->
        acked_caps = String.split(caps, " ", trim: true)
        state = %{state | active_caps: MapSet.union(state.active_caps, MapSet.new(acked_caps))}
        state = emit(state, {:cap_ack, acked_caps})
        state = emit(state, {:message, message})

        if should_start_sasl?(state, acked_caps) do
          state = select_first_sasl_mechanism(state)
          send_sasl_start(state)
          {:noreply, %{state | sasl_in_progress?: true}}
        else
          send_message(state, "CAP", ["END"])
          {:noreply, state}
        end

      {:ok, %Message{command: "CAP", params: [_nick, "NAK", caps]} = message} ->
        nacked_caps = String.split(caps, " ", trim: true)
        state = emit(state, {:cap_nak, nacked_caps})
        state = emit(state, {:message, message})
        send_message(state, "CAP", ["END"])
        {:noreply, state}

      {:ok, %Message{command: "CAP", params: [_nick, "NEW", caps]} = message} ->
        new_caps = parse_caps(caps)
        state = %{state | available_caps: Map.merge(state.available_caps, new_caps)}
        state = emit(state, {:cap_new, new_caps})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "CAP", params: [_nick, "DEL", caps]} = message} ->
        deleted_caps = String.split(caps, " ", trim: true)

        state = %{
          state
          | available_caps: Map.drop(state.available_caps, deleted_caps),
            active_caps: MapSet.difference(state.active_caps, MapSet.new(deleted_caps))
        }

        state = emit(state, {:cap_del, deleted_caps})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "AUTHENTICATE", params: ["+"]} = message} ->
        state = emit(state, {:message, message})
        send_sasl_plain(state)
        {:noreply, state}

      {:ok, %Message{command: "903"} = message} ->
        state = emit(state, :sasl_success)
        state = emit(state, {:message, message})
        send_message(state, "CAP", ["END"])
        {:noreply, %{state | sasl_in_progress?: false}}

      {:ok, %Message{command: command} = message}
      when command in ["904", "905", "906", "907", "908"] ->
        handle_sasl_failure(state, command, message)

      {:ok, %Message{command: "001"} = message} ->
        state = %{state | registered?: true}
        state = emit(state, :registered)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "005"} = message} ->
        state = emit(state, {:isupport, ISupport.parse_params(message.params)})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "433", params: params} = message} ->
        attempted = Enum.at(params, 1) || state.current_nick
        next_nick = state.nick_retry_fun.(attempted, state)
        send_message(state, "NICK", [next_nick])
        state = %{state | current_nick: next_nick}
        state = emit(state, {:nick_in_use, %{attempted: attempted, next: next_nick}})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "353", params: [_nick, symbol, channel, names]} = message} ->
        state =
          emit(
            state,
            {:names, %{symbol: symbol, channel: channel, names: Names.parse_names(names)}}
          )

        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "352"} = message} ->
        state = emit(state, {:who_reply, Who.parse_reply(message.params)})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "354"} = message} ->
        state = emit(state, {:whox_reply, Who.parse_whox(message.params)})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "315", params: [_me, mask | _rest]} = message} ->
        state = emit(state, {:who_end, %{mask: mask}})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: command, params: params} = message}
      when command in ["730", "731", "732", "733", "734"] ->
        state = emit_event(state, monitor_event(command, params, message), message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: command, params: params} = message}
      when command in ["760", "761", "766", "770", "771", "772", "774"] ->
        state = emit_event(state, metadata_reply_event(command, params, message), message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: command} = message}
      when command in ["311", "312", "313", "317", "319", "330", "338", "379", "671", "318"] ->
        state = emit_event(state, whois_event(command, message.params), message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "BATCH"} = message} ->
        handle_batch(message, state)

      {:ok, %Message{} = message} ->
        state = emit_event(state, event_for(message), message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:error, reason} ->
        state = emit(state, {:parse_error, reason, line})
        {:noreply, state}
    end
  end

  defp collect_caps(state, caps) do
    %{state | available_caps: Map.merge(state.available_caps, parse_caps(caps))}
  end

  defp parse_caps(caps) do
    caps
    |> String.split(" ", trim: true)
    |> Map.new(fn cap ->
      case String.split(cap, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, true}
      end
    end)
  end

  defp cap_list_complete?(%Message{params: [_nick, "LS", "*" | _]}), do: false
  defp cap_list_complete?(_), do: true

  defp request_caps_or_end(state) do
    requested =
      state.caps
      |> maybe_include_sasl(state)
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(state.available_caps, &1))

    if requested == [] do
      send_message(state, "CAP", ["END"])
    else
      send_message(state, "CAP", ["REQ", Enum.join(requested, " ")])
    end

    state = emit(state, {:cap_ls, state.available_caps})
    {:noreply, state}
  end

  defp event_for(%Message{command: "PRIVMSG", source: source, params: [target, body]} = message) do
    parsed_source = Source.parse(source)

    {:privmsg,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       target: target,
       body: body,
       ctcp: Ircxd.CTCP.decode(body),
       server_time: tag_value(message, &Tags.server_time/1),
       msgid: Tags.msgid(message),
       batch: Tags.batch(message),
       account: Tags.account(message),
       message: message
     }}
  end

  defp event_for(%Message{command: "NOTICE", source: source, params: [target, body]} = message) do
    parsed_source = Source.parse(source)

    {:notice,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       target: target,
       body: body,
       ctcp: Ircxd.CTCP.decode(body),
       server_time: tag_value(message, &Tags.server_time/1),
       msgid: Tags.msgid(message),
       batch: Tags.batch(message),
       account: Tags.account(message),
       message: message
     }}
  end

  defp event_for(%Message{command: "TAGMSG", source: source, params: [target]} = message) do
    parsed_source = Source.parse(source)

    {:tagmsg,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       target: target,
       tags: message.tags,
       server_time: tag_value(message, &Tags.server_time/1),
       msgid: Tags.msgid(message),
       batch: Tags.batch(message),
       account: Tags.account(message),
       message: message
     }}
  end

  defp event_for(%Message{command: "JOIN", source: source, params: [channel]} = message) do
    parsed_source = Source.parse(source)

    {:join,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       channel: channel,
       account: nil,
       realname: nil,
       message: message
     }}
  end

  defp event_for(
         %Message{command: "JOIN", source: source, params: [channel, account, realname]} = message
       ) do
    parsed_source = Source.parse(source)

    {:join,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       channel: channel,
       account: normalize_account(account),
       realname: realname,
       message: message
     }}
  end

  defp event_for(%Message{command: "PART", source: source, params: [channel | rest]} = message) do
    parsed_source = Source.parse(source)

    {:part,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       channel: channel,
       reason: List.first(rest),
       message: message
     }}
  end

  defp event_for(%Message{command: "ACCOUNT", source: source, params: [account]} = message) do
    parsed_source = Source.parse(source)
    account = normalize_account(account)

    {:account,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       account: account,
       logged_in?: not is_nil(account),
       message: message
     }}
  end

  defp event_for(%Message{command: "AWAY", source: source, params: params} = message) do
    parsed_source = Source.parse(source)
    away_message = List.first(params)

    {:away,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       away?: not is_nil(away_message),
       message: away_message,
       raw_message: message
     }}
  end

  defp event_for(%Message{command: "CHGHOST", source: source, params: [username, host]} = message) do
    parsed_source = Source.parse(source)

    {:chghost,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       username: username,
       host: host,
       message: message
     }}
  end

  defp event_for(%Message{command: "SETNAME", source: source, params: [realname]} = message) do
    parsed_source = Source.parse(source)

    {:setname,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       realname: realname,
       message: message
     }}
  end

  defp event_for(
         %Message{command: "RENAME", source: source, params: [old_channel, new_channel | rest]} =
           message
       ) do
    parsed_source = Source.parse(source)

    {:channel_rename,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       old_channel: old_channel,
       new_channel: new_channel,
       reason: List.first(rest),
       message: message
     }}
  end

  defp event_for(%Message{command: "INVITE", source: source, params: [target, channel]} = message) do
    parsed_source = Source.parse(source)

    {:invite,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       target: target,
       channel: channel,
       message: message
     }}
  end

  defp event_for(%Message{command: "METADATA", params: params} = message) do
    case Metadata.parse_message(params) do
      {:ok, metadata} -> {:metadata, Map.put(metadata, :message, message)}
      {:error, reason} -> {:metadata_error, %{reason: reason, message: message}}
    end
  end

  defp event_for(%Message{command: "CHATHISTORY", params: ["TARGETS" | params]} = message) do
    case ChatHistory.parse_targets(params) do
      {:ok, target} -> {:chathistory_target, Map.put(target, :message, message)}
      {:error, reason} -> {:chathistory_error, %{reason: reason, message: message}}
    end
  end

  defp event_for(%Message{command: "ACK"} = message) do
    {:ack, %{label: Tags.label(message), message: message}}
  end

  defp event_for(%Message{command: "QUIT", source: source, params: params} = message) do
    parsed_source = Source.parse(source)

    {:quit,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       reason: List.first(params),
       message: message
     }}
  end

  defp event_for(%Message{command: "NICK", source: source, params: [new_nick]} = message) do
    parsed_source = Source.parse(source)

    {:nick,
     %{
       source: parsed_source,
       raw_source: source,
       old_nick: parsed_source && parsed_source.nick,
       new_nick: new_nick,
       message: message
     }}
  end

  defp event_for(
         %Message{command: "KICK", source: source, params: [channel, nick | rest]} = message
       ) do
    parsed_source = Source.parse(source)

    {:kick,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       channel: channel,
       target_nick: nick,
       reason: List.first(rest),
       message: message
     }}
  end

  defp event_for(%Message{command: "TOPIC", source: source, params: [channel, topic]} = message) do
    parsed_source = Source.parse(source)

    {:topic,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       channel: channel,
       topic: topic,
       message: message
     }}
  end

  defp event_for(
         %Message{command: "MODE", source: source, params: [target, modes | mode_params]} =
           message
       ) do
    parsed_source = Source.parse(source)

    {:mode,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       target: target,
       modes: modes,
       params: mode_params,
       message: message
     }}
  end

  defp event_for(%Message{command: "ERROR", params: params} = message) do
    {:error, %{reason: List.first(params), message: message}}
  end

  defp event_for(%Message{command: command, params: params} = message)
       when command in ["FAIL", "WARN", "NOTE"] do
    case StandardReply.parse(command, params) do
      {:ok, reply} -> {:standard_reply, Map.put(reply, :message, message)}
      {:error, reason} -> {:standard_reply_error, %{reason: reason, message: message}}
    end
  end

  defp event_for(message), do: {:raw, message}

  defp whois_event("311", params), do: {:whois_user, Whois.parse_user(params)}
  defp whois_event("312", params), do: {:whois_server, Whois.parse_server(params)}
  defp whois_event("313", params), do: {:whois_operator, Whois.parse_operator(params)}
  defp whois_event("317", params), do: {:whois_idle, Whois.parse_idle(params)}
  defp whois_event("319", params), do: {:whois_channels, Whois.parse_channels(params)}
  defp whois_event("330", params), do: {:whois_account, Whois.parse_account(params)}
  defp whois_event("338", params), do: {:whois_actual_host, Whois.parse_actual_host(params)}
  defp whois_event("379", params), do: {:whois_modes, Whois.parse_modes(params)}
  defp whois_event("671", params), do: {:whois_secure, Whois.parse_secure(params)}
  defp whois_event("318", params), do: {:whois_end, Whois.parse_end(params)}

  defp handle_batch(%Message{params: params} = message, state) do
    case Batch.parse(params) do
      {:ok, %{direction: :start, ref: ref, type: type, params: batch_params}} ->
        batch = %{type: type, params: batch_params, message: message}
        state = %{state | active_batches: Map.put(state.active_batches, ref, batch)}
        state = maybe_start_multiline(state, ref, batch)
        state = maybe_start_labeled_response_batch(state, ref, batch)
        state = maybe_start_metadata_batch(state, ref, batch)
        state = emit(state, {:batch_start, Map.put(batch, :ref, ref)})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %{direction: :end, ref: ref}} ->
        {batch, active_batches} = Map.pop(state.active_batches, ref)
        state = %{state | active_batches: active_batches}
        state = maybe_emit_multiline(state, ref, batch)
        state = maybe_emit_labeled_response_batch(state, ref, batch)
        state = maybe_emit_metadata_batch(state, ref, batch)
        state = emit(state, {:batch_end, %{ref: ref, batch: batch}})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:error, reason} ->
        state = emit(state, {:batch_error, %{reason: reason, message: message}})
        state = emit(state, {:message, message})
        {:noreply, state}
    end
  end

  defp emit_event(state, event, message) do
    {state, event} = maybe_mark_duplicate_msgid(state, event)

    if buffer_server_time?(state, event) do
      entry = %{
        time: server_time_from_event(event),
        event: event,
        message: message,
        index: length(state.server_time_buffer)
      }

      state
      |> Map.update!(:server_time_buffer, &[entry | &1])
      |> maybe_schedule_server_time_flush()
    else
      emit_event_now(state, event, message)
    end
  end

  defp flush_server_time_buffer(state) do
    state.server_time_buffer
    |> Enum.sort_by(fn %{time: time, index: index} ->
      {DateTime.to_unix(time, :microsecond), index}
    end)
    |> Enum.reduce(%{state | server_time_buffer: []}, fn %{event: event, message: message},
                                                         state ->
      emit_event_now(state, event, message)
    end)
  end

  defp emit_event_now(state, event, message) do
    state =
      state
      |> maybe_emit_duplicate_msgid(event)
      |> emit(event)
      |> maybe_emit_labeled_response(event, message)
      |> maybe_emit_batched(event, message)

    state
  end

  defp buffer_server_time?(%{server_time_order: :manual}, event) do
    match?(%DateTime{}, server_time_from_event(event))
  end

  defp buffer_server_time?(%{server_time_order: opts}, event) when is_list(opts) do
    Keyword.has_key?(opts, :flush_after) and match?(%DateTime{}, server_time_from_event(event))
  end

  defp buffer_server_time?(_state, _event), do: false

  defp maybe_schedule_server_time_flush(
         %{server_time_order: opts, server_time_flush_timer: nil} = state
       )
       when is_list(opts) do
    delay = Keyword.fetch!(opts, :flush_after)
    %{state | server_time_flush_timer: Process.send_after(self(), :flush_server_time, delay)}
  end

  defp maybe_schedule_server_time_flush(state), do: state

  defp server_time_from_event({_name, %{server_time: %DateTime{} = server_time}}), do: server_time
  defp server_time_from_event(_event), do: nil

  defp maybe_mark_duplicate_msgid(
         %{msgid_dedupe: :mark} = state,
         {name, %{msgid: msgid} = payload}
       )
       when is_binary(msgid) do
    duplicate? = MapSet.member?(state.seen_msgids, msgid)
    state = %{state | seen_msgids: MapSet.put(state.seen_msgids, msgid)}
    {state, {name, Map.put(payload, :duplicate_msgid?, duplicate?)}}
  end

  defp maybe_mark_duplicate_msgid(state, event), do: {state, event}

  defp maybe_emit_duplicate_msgid(
         state,
         {_name, %{duplicate_msgid?: true, msgid: msgid} = payload} = event
       ) do
    emit(state, {:duplicate_msgid, %{msgid: msgid, event: event, message: payload.message}})
  end

  defp maybe_emit_duplicate_msgid(state, _event), do: state

  defp maybe_emit_labeled_response(state, event, message) do
    state = maybe_ack_labeled_request(state, event)

    case Tags.label(message) do
      nil -> state
      label -> emit(state, {:labeled_response, %{label: label, event: event, message: message}})
    end
  end

  defp maybe_track_labeled_request(state, %Message{tags: %{"label" => label}} = message) do
    request = %{label: label, command: message.command, params: message.params, status: :sent}

    state
    |> Map.update!(:labeled_requests, &Map.put(&1, label, request))
    |> emit({:labeled_request, request})
  end

  defp maybe_track_labeled_request(state, _message), do: state

  defp maybe_ack_labeled_request(state, {:ack, %{label: label}}) when is_binary(label) do
    case Map.fetch(state.labeled_requests, label) do
      {:ok, request} ->
        request = Map.put(request, :status, :acknowledged)

        state
        |> Map.update!(:labeled_requests, &Map.put(&1, label, request))
        |> emit({:labeled_request, request})

      :error ->
        state
    end
  end

  defp maybe_ack_labeled_request(state, _event), do: state

  defp complete_labeled_request(state, label, response_type) do
    case Map.fetch(state.labeled_requests, label) do
      {:ok, request} ->
        request =
          request
          |> Map.put(:status, :completed)
          |> Map.put(:response_type, response_type)

        state
        |> Map.update!(:labeled_requests, &Map.delete(&1, label))
        |> emit({:labeled_request, request})

      :error ->
        state
    end
  end

  defp maybe_emit_batched(state, event, message) do
    case Tags.batch(message) do
      nil ->
        state

      ref ->
        state = maybe_collect_multiline(state, ref, event, message)
        state = maybe_collect_labeled_response_batch(state, ref, event)
        state = maybe_collect_metadata_batch(state, ref, event)

        emit(
          state,
          {:batched,
           %{ref: ref, batch: Map.get(state.active_batches, ref), event: event, message: message}}
        )
    end
  end

  defp maybe_start_multiline(state, ref, %{type: "draft/multiline", params: [target | _rest]}) do
    multiline = %{target: target, lines: []}
    %{state | multiline_batches: Map.put(state.multiline_batches, ref, multiline)}
  end

  defp maybe_start_multiline(state, _ref, _batch), do: state

  defp maybe_collect_multiline(state, ref, {name, payload}, message)
       when name in [:privmsg, :notice] do
    case Map.fetch(state.multiline_batches, ref) do
      {:ok, multiline} ->
        line = %{
          body: payload.body,
          concat?: Map.has_key?(message.tags, Multiline.concat_tag()),
          event: {name, payload},
          message: message
        }

        multiline = %{multiline | lines: multiline.lines ++ [line]}
        %{state | multiline_batches: Map.put(state.multiline_batches, ref, multiline)}

      :error ->
        state
    end
  end

  defp maybe_collect_multiline(state, _ref, _event, _message), do: state

  defp maybe_emit_multiline(state, ref, %{type: "draft/multiline"} = batch) do
    {multiline, multiline_batches} = Map.pop(state.multiline_batches, ref)
    state = %{state | multiline_batches: multiline_batches}

    case multiline do
      %{lines: [%{event: {command, first_payload}} | _rest] = lines, target: target} ->
        emit(
          state,
          {:multiline,
           %{
             ref: ref,
             batch: batch,
             target: target,
             command: command |> Atom.to_string() |> String.upcase(),
             body: Multiline.combine(lines),
             source: first_payload.source,
             raw_source: first_payload.raw_source,
             nick: first_payload.nick,
             lines: lines
           }}
        )

      _ ->
        state
    end
  end

  defp maybe_emit_multiline(state, ref, _batch) do
    %{state | multiline_batches: Map.delete(state.multiline_batches, ref)}
  end

  defp maybe_start_labeled_response_batch(
         state,
         ref,
         %{type: "labeled-response", message: message} = batch
       ) do
    case Tags.label(message) do
      nil ->
        state

      label ->
        labeled_batch = %{label: label, type: batch.type, params: batch.params, events: []}

        %{
          state
          | labeled_response_batches: Map.put(state.labeled_response_batches, ref, labeled_batch)
        }
    end
  end

  defp maybe_start_labeled_response_batch(state, _ref, _batch), do: state

  defp maybe_collect_labeled_response_batch(state, ref, event) do
    case Map.fetch(state.labeled_response_batches, ref) do
      {:ok, batch} ->
        batch = %{batch | events: batch.events ++ [event]}
        %{state | labeled_response_batches: Map.put(state.labeled_response_batches, ref, batch)}

      :error ->
        state
    end
  end

  defp maybe_emit_labeled_response_batch(state, ref, %{type: "labeled-response"}) do
    {batch, labeled_response_batches} = Map.pop(state.labeled_response_batches, ref)
    state = %{state | labeled_response_batches: labeled_response_batches}

    case batch do
      %{label: label, type: type, events: events} ->
        state
        |> emit(
          {:labeled_response,
           %{label: label, event: {:batch, %{ref: ref, type: type, events: events}}}}
        )
        |> complete_labeled_request(label, :batch)

      _ ->
        state
    end
  end

  defp maybe_emit_labeled_response_batch(state, ref, _batch) do
    %{state | labeled_response_batches: Map.delete(state.labeled_response_batches, ref)}
  end

  defp maybe_start_metadata_batch(state, ref, %{type: "metadata", params: params}) do
    metadata_batch = %{target: List.first(params), entries: []}
    %{state | metadata_batches: Map.put(state.metadata_batches, ref, metadata_batch)}
  end

  defp maybe_start_metadata_batch(state, _ref, _batch), do: state

  defp maybe_collect_metadata_batch(state, ref, {event_name, _payload} = event)
       when event_name in [:metadata_reply, :standard_reply] do
    case Map.fetch(state.metadata_batches, ref) do
      {:ok, batch} ->
        batch = %{batch | entries: batch.entries ++ [event]}
        %{state | metadata_batches: Map.put(state.metadata_batches, ref, batch)}

      :error ->
        state
    end
  end

  defp maybe_collect_metadata_batch(state, _ref, _event), do: state

  defp maybe_emit_metadata_batch(state, ref, %{type: "metadata"}) do
    {batch, metadata_batches} = Map.pop(state.metadata_batches, ref)
    state = %{state | metadata_batches: metadata_batches}

    case batch do
      %{entries: entries, target: target} ->
        emit(state, {:metadata_batch, %{ref: ref, target: target, entries: entries}})

      _ ->
        state
    end
  end

  defp maybe_emit_metadata_batch(state, ref, _batch) do
    %{state | metadata_batches: Map.delete(state.metadata_batches, ref)}
  end

  defp send_message(%{transport: nil}, _command, _params), do: {:error, :not_connected}

  defp send_message(state, command, params) do
    send_message(state, %Message{command: command, params: params})
  end

  defp send_message(%{transport: nil}, %Message{}), do: {:error, :not_connected}

  defp send_message(state, %Message{} = message) do
    with :ok <- validate_outbound_tags(state, message) do
      line = Message.serialize(message)

      case state.transport do
        :ssl -> :ssl.send(state.socket, line)
        :gen_tcp -> :gen_tcp.send(state.socket, line)
      end
    end
  end

  defp validate_outbound_tags(state, %Message{tags: tags}) when is_map_key(tags, "label") do
    with :ok <- require_active_cap(state, "labeled-response") do
      validate_client_only_tags(state, tags)
    end
  end

  defp validate_outbound_tags(state, %Message{tags: tags}),
    do: validate_client_only_tags(state, tags)

  defp validate_outbound_tags(_state, _message), do: :ok

  defp validate_client_only_tags(state, tags) do
    if Enum.any?(Map.keys(tags), &String.starts_with?(&1, "+")) do
      require_active_cap(state, "message-tags")
    else
      :ok
    end
  end

  defp require_active_cap(state, cap) do
    if MapSet.member?(state.active_caps, cap) do
      :ok
    else
      {:error, {:capability_not_enabled, cap}}
    end
  end

  defp maybe_include_sasl(caps, %{sasl: nil}), do: caps
  defp maybe_include_sasl(caps, _state), do: ["sasl" | caps]

  defp normalize_sasl(nil), do: []
  defp normalize_sasl({:plain, _username, _password} = mechanism), do: [mechanism]
  defp normalize_sasl({:external, _authzid} = mechanism), do: [mechanism]
  defp normalize_sasl(mechanisms) when is_list(mechanisms), do: mechanisms

  defp normalize_reconnect(false), do: nil
  defp normalize_reconnect(nil), do: nil
  defp normalize_reconnect(true), do: %{max_attempts: :infinity, delay: 1_000}

  defp normalize_reconnect(opts) when is_list(opts) do
    %{
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      delay: Keyword.get(opts, :delay, 1_000)
    }
  end

  defp should_start_sasl?(%{sasl: nil}, _acked_caps), do: false

  defp should_start_sasl?(%{sasl_mechanisms: mechanisms}, acked_caps),
    do: mechanisms != [] and "sasl" in acked_caps

  defp send_sasl_start(state) do
    send_message(state, "AUTHENTICATE", [current_sasl_mechanism_name(state)])
  end

  defp select_first_sasl_mechanism(state), do: %{state | sasl_index: 0}

  defp current_sasl_mechanism(%{sasl_mechanisms: mechanisms, sasl_index: index}) do
    Enum.at(mechanisms, index)
  end

  defp current_sasl_mechanism_name(state) do
    state
    |> current_sasl_mechanism()
    |> sasl_mechanism_name()
  end

  defp current_sasl_mechanism_atom(state) do
    state
    |> current_sasl_mechanism()
    |> sasl_mechanism_atom()
  end

  defp next_sasl_mechanism_atom(%{sasl_mechanisms: mechanisms, sasl_index: index}) do
    mechanisms
    |> Enum.at(index + 1)
    |> sasl_mechanism_atom()
  end

  defp sasl_mechanism_name({:plain, _username, _password}), do: "PLAIN"
  defp sasl_mechanism_name({:external, _authzid}), do: "EXTERNAL"
  defp sasl_mechanism_name(nil), do: nil

  defp sasl_mechanism_atom({:plain, _username, _password}), do: :plain
  defp sasl_mechanism_atom({:external, _authzid}), do: :external
  defp sasl_mechanism_atom(nil), do: nil

  defp send_sasl_plain(%{sasl_mechanisms: mechanisms, sasl_index: index} = state) do
    case Enum.at(mechanisms, index) do
      {:plain, username, password} ->
        username
        |> SASL.plain_payload(password)
        |> SASL.authenticate_chunks()
        |> Enum.each(&send_message(state, "AUTHENTICATE", [&1]))

      {:external, authzid} ->
        authzid
        |> SASL.external_payload()
        |> SASL.authenticate_chunks()
        |> Enum.each(&send_message(state, "AUTHENTICATE", [&1]))

      nil ->
        :ok
    end
  end

  defp send_sasl_plain(_state), do: :ok

  defp default_nick_retry(nick, _state), do: "#{nick}_"

  defp handle_sasl_failure(state, code, message) do
    policy = sasl_failure_policy(state)

    payload = %{
      code: code,
      policy: policy,
      mechanism: current_sasl_mechanism_atom(state),
      next_mechanism: next_sasl_mechanism_atom(state),
      message: message
    }

    state = emit(state, {:sasl_failure, payload})
    state = emit(state, {:message, message})
    state = %{state | sasl_in_progress?: false}

    case policy do
      :retry ->
        state = %{state | sasl_index: state.sasl_index + 1, sasl_in_progress?: true}
        send_sasl_start(state)
        {:noreply, state}

      :abort ->
        send_message(state, "QUIT", ["SASL authentication failed"])
        {:stop, :sasl_failure, state}

      :continue ->
        send_message(state, "CAP", ["END"])
        {:noreply, state}
    end
  end

  defp sasl_failure_policy(state) do
    cond do
      next_sasl_mechanism_atom(state) != nil -> :retry
      true -> state.sasl_failure_policy
    end
  end

  defp multiline_ref(state, opts) do
    case Keyword.get(opts, :ref) do
      nil ->
        ref = "ircxd-#{state.multiline_ref + 1}"
        {ref, %{state | multiline_ref: state.multiline_ref + 1}}

      ref ->
        {to_string(ref), state}
    end
  end

  defp send_multiline_lines(state, command, target, body, ref) do
    body
    |> Multiline.split()
    |> Enum.reduce_while(:ok, fn line, :ok ->
      tags =
        if line.concat? do
          %{"batch" => ref, Multiline.concat_tag() => true}
        else
          %{"batch" => ref}
        end

      case send_message(state, %Message{command: command, params: [target, line.body], tags: tags}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp join_targets(targets) when is_list(targets), do: Enum.join(targets, ",")
  defp join_targets(target) when is_binary(target), do: target

  defp tag_value(message, fun) do
    case fun.(message) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp normalize_account("*"), do: nil
  defp normalize_account(account), do: account

  defp monitor_event(command, params, message) do
    case Monitor.parse_numeric(command, params) do
      {:ok, payload} -> {:monitor, Map.put(payload, :message, message)}
      {:error, reason} -> {:monitor_error, %{reason: reason, message: message}}
    end
  end

  defp metadata_reply_event(command, params, message) do
    case Metadata.parse_numeric(command, params) do
      {:ok, payload} -> {:metadata_reply, Map.put(payload, :message, message)}
      {:error, reason} -> {:metadata_reply_error, %{reason: reason, message: message}}
    end
  end

  defp init_handler(state, nil), do: {:ok, state}

  defp init_handler(state, {module, arg}) do
    with {:ok, handler_state} <- module.init(arg) do
      {:ok, %{state | handler: module, handler_state: handler_state}}
    end
  end

  defp emit(state, event) do
    if state.notify, do: send(state.notify, {:ircxd, event})

    case state.handler do
      nil ->
        state

      module ->
        case module.handle_event(event, state.handler_state) do
          {:ok, handler_state} -> %{state | handler_state: handler_state}
          _ -> state
        end
    end
  end
end
