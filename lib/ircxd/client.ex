defmodule Ircxd.Client do
  @moduledoc """
  GenServer IRC client.

  Options:

    * `:host` - IRC server host.
    * `:port` - IRC server port.
    * `:tls` - true for implicit TLS.
    * `:sni` - TLS Server Name Indication hostname, defaults to `:host`.
    * `:tls_options` - additional Erlang `:ssl.connect/4` options.
    * `:password` - optional server password sent with `PASS` before registration.
    * `:nick` - desired nickname.
    * `:username` - username sent in registration.
    * `:realname` - realname sent in registration.
    * `:caps` - IRCv3 capabilities to request.
    * `:notify` - pid to receive `{:ircxd, event}` messages.
    * `:handler` - `{module, init_arg}` implementing `Ircxd.Handler`.
  """

  use GenServer

  alias Ircxd.Batch
  alias Ircxd.AccountExtban
  alias Ircxd.ChatHistory
  alias Ircxd.ClientTagDeny
  alias Ircxd.DCC
  alias Ircxd.FileHost
  alias Ircxd.Metadata
  alias Ircxd.Message
  alias Ircxd.Monitor
  alias Ircxd.Multiline
  alias Ircxd.Names
  alias Ircxd.SASL
  alias Ircxd.Source
  alias Ircxd.ISupport
  alias Ircxd.STS
  alias Ircxd.StandardReply
  alias Ircxd.Tags
  alias Ircxd.WebIRC
  alias Ircxd.Who
  alias Ircxd.Whois

  @tcp_opts [:binary, packet: :line, active: true]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def request_capabilities(client, caps) do
    GenServer.call(client, {:request_caps, List.wrap(caps)})
  end

  def pass(client, password), do: GenServer.call(client, {:send, "PASS", [password]})
  def nick(client, nick), do: GenServer.call(client, {:send, "NICK", [nick]})
  def join(client, channel), do: GenServer.call(client, {:send, "JOIN", [channel]})

  def names(client, target), do: GenServer.call(client, {:send, "NAMES", [target]})

  def list(client, channels \\ nil, server \\ nil)
  def list(client, nil, nil), do: GenServer.call(client, {:send, "LIST", []})

  def list(client, channels, nil),
    do: GenServer.call(client, {:send, "LIST", [join_targets(channels)]})

  def list(client, channels, server),
    do: GenServer.call(client, {:send, "LIST", [join_targets(channels), server]})

  def invite(client, nick, channel),
    do: GenServer.call(client, {:send, "INVITE", [nick, channel]})

  def part(client, channel, reason \\ ""),
    do: GenServer.call(client, {:send, "PART", [channel, reason]})

  def topic(client, channel, topic \\ nil)
  def topic(client, channel, nil), do: GenServer.call(client, {:send, "TOPIC", [channel]})

  def topic(client, channel, topic),
    do: GenServer.call(client, {:send, "TOPIC", [channel, topic]})

  def mode(client, target, modes, params \\ []),
    do: GenServer.call(client, {:send, "MODE", [target, modes | params]})

  def mode_query(client, target), do: GenServer.call(client, {:send, "MODE", [target]})
  def channel_modes(client, channel), do: mode_query(client, channel)
  def user_modes(client, nick), do: mode_query(client, nick)

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

  def reply(client, target, body, reply_to_msgid),
    do: privmsg(client, target, body, %{"+reply" => reply_to_msgid})

  def context_privmsg(client, target, channel_context, body),
    do: context_message(client, "PRIVMSG", target, channel_context, body)

  def notice(client, target, body), do: GenServer.call(client, {:send, "NOTICE", [target, body]})

  def notice(client, target, body, tags) when is_map(tags),
    do:
      GenServer.call(
        client,
        {:send, %Message{command: "NOTICE", params: [target, body], tags: tags}}
      )

  def context_notice(client, target, channel_context, body),
    do: context_message(client, "NOTICE", target, channel_context, body)

  def tagmsg(client, target, tags) when is_map(tags),
    do: GenServer.call(client, {:send, %Message{command: "TAGMSG", params: [target], tags: tags}})

  def typing(client, target, status) when status in [:active, :paused, :done],
    do: tagmsg(client, target, %{"+typing" => Atom.to_string(status)})

  def typing(_client, _target, _status), do: {:error, :invalid_typing_status}

  def react(client, target, reply_to_msgid, reaction),
    do: reaction_tagmsg(client, target, reply_to_msgid, "+draft/react", reaction)

  def unreact(client, target, reply_to_msgid, reaction),
    do: reaction_tagmsg(client, target, reply_to_msgid, "+draft/unreact", reaction)

  def redact(client, target, msgid, reason \\ nil)

  def redact(client, target, msgid, nil),
    do: GenServer.call(client, {:send, "REDACT", [target, msgid]})

  def redact(client, target, msgid, reason),
    do: GenServer.call(client, {:send, "REDACT", [target, msgid, reason]})

  def setname(client, realname), do: GenServer.call(client, {:send, "SETNAME", [realname]})

  def rename(client, old_channel, new_channel, reason \\ nil)

  def rename(client, old_channel, new_channel, nil),
    do: GenServer.call(client, {:send, "RENAME", [old_channel, new_channel]})

  def rename(client, old_channel, new_channel, reason),
    do: GenServer.call(client, {:send, "RENAME", [old_channel, new_channel, reason]})

  def quit(client, reason \\ "leaving"), do: GenServer.call(client, {:send, "QUIT", [reason]})
  def raw(client, command, params \\ []), do: GenServer.call(client, {:send, command, params})

  def motd(client, target \\ nil)
  def motd(client, nil), do: GenServer.call(client, {:send, "MOTD", []})
  def motd(client, target), do: GenServer.call(client, {:send, "MOTD", [target]})

  def version(client, target \\ nil)
  def version(client, nil), do: GenServer.call(client, {:send, "VERSION", []})
  def version(client, target), do: GenServer.call(client, {:send, "VERSION", [target]})

  def admin(client, target \\ nil)
  def admin(client, nil), do: GenServer.call(client, {:send, "ADMIN", []})
  def admin(client, target), do: GenServer.call(client, {:send, "ADMIN", [target]})

  def lusers(client, mask \\ nil, target \\ nil)
  def lusers(client, nil, nil), do: GenServer.call(client, {:send, "LUSERS", []})
  def lusers(client, mask, nil), do: GenServer.call(client, {:send, "LUSERS", [mask]})
  def lusers(client, mask, target), do: GenServer.call(client, {:send, "LUSERS", [mask, target]})

  def time(client, target \\ nil)
  def time(client, nil), do: GenServer.call(client, {:send, "TIME", []})
  def time(client, target), do: GenServer.call(client, {:send, "TIME", [target]})

  def stats(client, query \\ nil, target \\ nil)
  def stats(client, nil, nil), do: GenServer.call(client, {:send, "STATS", []})
  def stats(client, query, nil), do: GenServer.call(client, {:send, "STATS", [query]})
  def stats(client, query, target), do: GenServer.call(client, {:send, "STATS", [query, target]})

  def help(client, subject \\ nil)
  def help(client, nil), do: GenServer.call(client, {:send, "HELP", []})
  def help(client, subject), do: GenServer.call(client, {:send, "HELP", [subject]})

  def info(client, target \\ nil)
  def info(client, nil), do: GenServer.call(client, {:send, "INFO", []})
  def info(client, target), do: GenServer.call(client, {:send, "INFO", [target]})

  def who(client, mask, options \\ nil)
  def who(client, mask, nil), do: GenServer.call(client, {:send, "WHO", [mask]})
  def who(client, mask, options), do: GenServer.call(client, {:send, "WHO", [mask, options]})
  def whois(client, nick), do: GenServer.call(client, {:send, "WHOIS", [nick]})
  def whowas(client, nick, count \\ nil)
  def whowas(client, nick, nil), do: GenServer.call(client, {:send, "WHOWAS", [nick]})
  def whowas(client, nick, count), do: GenServer.call(client, {:send, "WHOWAS", [nick, count]})

  def links(client, remote_server \\ nil, mask \\ nil)
  def links(client, nil, nil), do: GenServer.call(client, {:send, "LINKS", []})

  def links(client, remote_server, nil),
    do: GenServer.call(client, {:send, "LINKS", [remote_server]})

  def links(client, remote_server, mask),
    do: GenServer.call(client, {:send, "LINKS", [remote_server, mask]})

  def userhost(client, nicks),
    do: GenServer.call(client, {:send, "USERHOST", List.wrap(nicks)})

  def ison(client, nicks), do: GenServer.call(client, {:send, "ISON", List.wrap(nicks)})

  def wallops(client, message), do: GenServer.call(client, {:send, "WALLOPS", [message]})

  def oper(client, name, password), do: GenServer.call(client, {:send, "OPER", [name, password]})

  def kill(client, nick, comment),
    do: GenServer.call(client, {:send, "KILL", [nick, comment]})

  def squery(client, service, text),
    do: GenServer.call(client, {:send, "SQUERY", [service, text]})

  def trace(client, target \\ nil)
  def trace(client, nil), do: GenServer.call(client, {:send, "TRACE", []})
  def trace(client, target), do: GenServer.call(client, {:send, "TRACE", [target]})

  def connect_server(client, target_server, port, remote_server \\ nil)

  def connect_server(client, target_server, port, nil),
    do: GenServer.call(client, {:send, "CONNECT", [target_server, to_string(port)]})

  def connect_server(client, target_server, port, remote_server),
    do:
      GenServer.call(client, {:send, "CONNECT", [target_server, to_string(port), remote_server]})

  def squit(client, server, comment),
    do: GenServer.call(client, {:send, "SQUIT", [server, comment]})

  def rehash(client), do: GenServer.call(client, {:send, "REHASH", []})
  def restart(client), do: GenServer.call(client, {:send, "RESTART", []})

  def summon(client, user, target \\ nil, channel \\ nil)
  def summon(client, user, nil, nil), do: GenServer.call(client, {:send, "SUMMON", [user]})

  def summon(client, user, target, nil),
    do: GenServer.call(client, {:send, "SUMMON", [user, target]})

  def summon(client, user, target, channel),
    do: GenServer.call(client, {:send, "SUMMON", [user, target, channel]})

  def users(client, target \\ nil)
  def users(client, nil), do: GenServer.call(client, {:send, "USERS", []})
  def users(client, target), do: GenServer.call(client, {:send, "USERS", [target]})

  def servlist(client, mask \\ nil, type \\ nil)
  def servlist(client, nil, nil), do: GenServer.call(client, {:send, "SERVLIST", []})
  def servlist(client, mask, nil), do: GenServer.call(client, {:send, "SERVLIST", [mask]})
  def servlist(client, mask, type), do: GenServer.call(client, {:send, "SERVLIST", [mask, type]})

  def bot_mode(client, enabled \\ true), do: GenServer.call(client, {:bot_mode, enabled})

  def account_extban_mask(client, account, preferred_name \\ nil),
    do: GenServer.call(client, {:account_extban_mask, account, preferred_name})

  def client_tag_denied?(client, tag), do: GenServer.call(client, {:client_tag_denied?, tag})

  def register_account(client, account, email, password),
    do: GenServer.call(client, {:send, "REGISTER", [account, email, password]})

  def verify_account(client, account, code),
    do: GenServer.call(client, {:send, "VERIFY", [account, code]})

  def away(client, message \\ nil)
  def away(client, nil), do: GenServer.call(client, {:send, "AWAY", []})
  def away(client, message), do: GenServer.call(client, {:send, "AWAY", [message]})

  def preaway_unspecified(client), do: GenServer.call(client, {:send, "AWAY", ["*"]})

  def markread_get(client, target), do: GenServer.call(client, {:send, "MARKREAD", [target]})

  def markread_set(client, target, timestamp),
    do: GenServer.call(client, {:send, "MARKREAD", [target, "timestamp=#{timestamp}"]})

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

  def isupport(client), do: GenServer.call(client, :send_isupport)
  def filehost_upload_url(client), do: GenServer.call(client, :filehost_upload_url)

  def raw_tagged(client, command, params, tags),
    do: GenServer.call(client, {:send, %Message{command: command, params: params, tags: tags}})

  def labeled_raw(client, label, command, params \\ []),
    do: raw_tagged(client, command, params, %{"label" => label})

  def transmit(client, %Message{} = message), do: GenServer.call(client, {:send, message})
  def flush_server_time(client), do: GenServer.call(client, :flush_server_time)

  def client_batch(client, reference, type, params, messages, opts \\ []) do
    GenServer.call(client, {:send_client_batch, reference, type, params, messages, opts})
  end

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
      sni: Keyword.get(opts, :sni, Keyword.fetch!(opts, :host)),
      tls_options: Keyword.get(opts, :tls_options, []),
      password: Keyword.get(opts, :password),
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
      isupport: %{},
      current_nick: Keyword.fetch!(opts, :nick),
      nick_retry_fun: Keyword.get(opts, :nick_retry_fun, &default_nick_retry/2),
      sasl: Keyword.get(opts, :sasl),
      sasl_mechanisms: normalize_sasl(Keyword.get(opts, :sasl)),
      sasl_index: 0,
      sasl_scram: nil,
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
      isupport_batches: %{},
      metadata_batches: %{},
      net_batches: %{},
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
      maybe_send_pass(state)
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

  def handle_call({:request_caps, caps}, _from, state) do
    caps = caps |> Enum.map(&to_string/1) |> Enum.uniq()

    result =
      with :ok <- ensure_caps_available(state, caps) do
        send_message(state, "CAP", ["REQ", Enum.join(caps, " ")])
      end

    case result do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:bot_mode, enabled}, _from, state) do
    case Map.fetch(state.isupport, "BOT") do
      {:ok, mode} when is_binary(mode) ->
        sign = if enabled, do: "+", else: "-"

        case send_message(state, "MODE", [state.current_nick, sign <> mode]) do
          :ok -> {:reply, :ok, state}
          error -> {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :bot_mode_not_supported}, state}
    end
  end

  def handle_call({:account_extban_mask, account, preferred_name}, _from, state) do
    {:reply, AccountExtban.mask(state.isupport, account, preferred_name), state}
  end

  def handle_call({:client_tag_denied?, tag}, _from, state) do
    {:reply, ClientTagDeny.denied?(state.isupport["CLIENTTAGDENY"], tag), state}
  end

  def handle_call(:filehost_upload_url, _from, state) do
    {:reply, FileHost.upload_url(state.isupport, state.tls), state}
  end

  def handle_call(:send_isupport, _from, state) do
    result =
      with :ok <- require_active_cap(state, "draft/extended-isupport") do
        send_message(state, "ISUPPORT", [])
      end

    case result do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:flush_server_time, _from, state) do
    {:reply, :ok, flush_server_time_buffer(state)}
  end

  def handle_call({:send_client_batch, reference, type, params, messages, opts}, _from, state) do
    result =
      with :ok <- require_client_batch_cap(state, opts),
           {:ok, messages} <- normalize_client_batch_messages(messages),
           :ok <- validate_client_batch_messages(messages) do
        send_client_batch(state, reference, type, params, messages)
      end

    case result do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:send_multiline, command, target, body, opts}, _from, state) do
    {ref, state} = multiline_ref(state, opts)

    result =
      with :ok <- require_active_cap(state, "batch"),
           :ok <- require_active_cap(state, "draft/multiline"),
           :ok <- require_active_cap(state, "message-tags"),
           :ok <- send_message(state, "BATCH", ["+" <> ref, "draft/multiline", target]),
           :ok <- send_multiline_lines(state, command, target, body, ref) do
        send_message(state, "BATCH", ["-" <> ref])
      end

    case result do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @doc false
  def __tls_connect_options__(state) do
    default_sni = [
      server_name_indication:
        state
        |> Map.get(:sni, Map.fetch!(state, :host))
        |> String.to_charlist()
    ]

    Keyword.merge(default_sni, Map.get(state, :tls_options, []))
  end

  defp connect(%{tls: true} = state) do
    with {:ok, socket} <-
           :ssl.connect(
             String.to_charlist(state.host),
             state.port,
             @tcp_opts ++ __tls_connect_options__(state),
             10_000
           ) do
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

  defp maybe_send_pass(%{password: nil}), do: :ok
  defp maybe_send_pass(%{password: ""}), do: :ok
  defp maybe_send_pass(%{password: password} = state), do: send_message(state, "PASS", [password])

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
          isupport: %{},
          active_batches: %{},
          multiline_batches: %{},
          labeled_response_batches: %{},
          labeled_requests: %{},
          isupport_batches: %{},
          metadata_batches: %{},
          net_batches: %{},
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
        state = maybe_emit_sts_policy(state, new_caps)
        state = emit(state, {:cap_new, new_caps})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "CAP", params: [_nick, "DEL", caps]} = message} ->
        deleted_caps = String.split(caps, " ", trim: true)
        deleted_caps = Enum.reject(deleted_caps, &(&1 == "sts"))

        state = %{
          state
          | available_caps: Map.drop(state.available_caps, deleted_caps),
            active_caps: MapSet.difference(state.active_caps, MapSet.new(deleted_caps))
        }

        state = emit(state, {:cap_del, deleted_caps})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "AUTHENTICATE", params: [payload]} = message} ->
        state = emit(state, {:message, message})
        {:noreply, handle_sasl_authenticate(state, payload)}

      {:ok, %Message{command: "903"} = message} ->
        if sasl_scram_verified_or_unused?(state) do
          state = emit(state, :sasl_success)
          state = emit(state, {:message, message})
          send_message(state, "CAP", ["END"])
          {:noreply, %{state | sasl_in_progress?: false, sasl_scram: nil}}
        else
          state = emit(state, {:sasl_scram_error, %{reason: :missing_verified_server_final}})
          state = emit(state, {:message, message})
          send_message(state, "QUIT", ["SASL SCRAM verification failed"])
          {:stop, :sasl_failure, state}
        end

      {:ok, %Message{command: "908", params: [_nick, mechanisms | _rest]} = message} ->
        state = emit(state, {:sasl_mechanisms, %{mechanisms: parse_sasl_mechanisms(mechanisms)}})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: command} = message}
      when command in ["904", "905", "906", "907"] ->
        handle_sasl_failure(state, command, message)

      {:ok, %Message{command: "001"} = message} ->
        state = %{state | registered?: true}
        state = emit(state, :registered)
        state = emit_event(state, event_for(message), message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "005"} = message} ->
        tokens = ISupport.parse_params(message.params)
        state = %{state | isupport: Map.merge(state.isupport, tokens)}
        state = emit_event(state, {:isupport, tokens}, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "105"} = message} ->
        tokens = ISupport.parse_params(message.params)
        state = emit_event(state, {:remote_isupport, tokens}, message)
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

      {:ok, %Message{command: "366", params: [_nick, channel | _rest]} = message} ->
        state = emit(state, {:names_end, %{channel: channel, message: message}})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "352"} = message} ->
        state = emit(state, {:who_reply, Who.parse_reply(message.params, state.isupport["BOT"])})
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
      when command in [
             "311",
             "312",
             "313",
             "314",
             "276",
             "307",
             "317",
             "319",
             "330",
             "335",
             "338",
             "320",
             "378",
             "379",
             "671",
             "318",
             "369"
           ] ->
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
      |> Enum.reject(&(&1 == "sts"))
      |> Enum.filter(&Map.has_key?(state.available_caps, &1))

    state = maybe_emit_sts_policy(state, state.available_caps)

    if requested == [] do
      send_message(state, "CAP", ["END"])
    else
      send_message(state, "CAP", ["REQ", Enum.join(requested, " ")])
    end

    state = emit(state, {:cap_ls, state.available_caps})
    {:noreply, state}
  end

  defp maybe_emit_sts_policy(state, %{"sts" => value}) do
    case STS.parse(value, state.tls) do
      {:ok, policy} ->
        emit(
          state,
          {:sts_policy,
           policy
           |> Map.put(:host, state.host)
           |> Map.put(:tls?, state.tls)}
        )

      {:error, reason} ->
        emit(state, {:sts_policy_error, %{host: state.host, value: value, reason: reason}})
    end
  end

  defp maybe_emit_sts_policy(state, _caps), do: state

  defp event_for(%Message{command: "PRIVMSG", source: source, params: [target, body]} = message) do
    parsed_source = Source.parse(source)
    ctcp = Ircxd.CTCP.decode(body)

    {:privmsg,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       target: target,
       body: body,
       ctcp: ctcp,
       dcc: dcc_from_ctcp(ctcp),
       server_time: tag_value(message, &Tags.server_time/1),
       msgid: Tags.msgid(message),
       reply_to_msgid: Tags.reply_to_msgid(message),
       channel_context: Tags.channel_context(message),
       batch: Tags.batch(message),
       account: Tags.account(message),
       bot?: Tags.bot?(message),
       message: message
     }}
  end

  defp event_for(%Message{command: "NOTICE", source: source, params: [target, body]} = message) do
    parsed_source = Source.parse(source)
    ctcp = Ircxd.CTCP.decode(body)

    {:notice,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       target: target,
       body: body,
       ctcp: ctcp,
       dcc: dcc_from_ctcp(ctcp),
       server_time: tag_value(message, &Tags.server_time/1),
       msgid: Tags.msgid(message),
       reply_to_msgid: Tags.reply_to_msgid(message),
       channel_context: Tags.channel_context(message),
       batch: Tags.batch(message),
       account: Tags.account(message),
       bot?: Tags.bot?(message),
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
       bot?: Tags.bot?(message),
       message: message
     }}
  end

  defp event_for(
         %Message{command: "REDACT", source: source, params: [target, msgid | rest]} = message
       ) do
    parsed_source = Source.parse(source)

    {:redact,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && parsed_source.nick,
       target: target,
       msgid: msgid,
       reason: List.first(rest),
       server_time: tag_value(message, &Tags.server_time/1),
       batch: Tags.batch(message),
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
       unspecified?: away_message == "*",
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

  defp event_for(%Message{command: "MARKREAD", params: [target, timestamp]} = message) do
    case parse_markread_timestamp(timestamp) do
      {:ok, parsed_timestamp} ->
        {:read_marker,
         %{
           target: target,
           timestamp: parsed_timestamp,
           known?: not is_nil(parsed_timestamp),
           message: message
         }}

      {:error, reason} ->
        {:read_marker_error,
         %{target: target, timestamp: timestamp, reason: reason, message: message}}
    end
  end

  defp event_for(%Message{command: command, params: [status, account, message_text]} = message)
       when command in ["REGISTER", "VERIFY"] do
    {:account_registration,
     %{
       command: command,
       status: parse_account_registration_status(status),
       account: account,
       message: message_text,
       raw_status: status,
       raw_message: message
     }}
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

  defp event_for(%Message{command: "001", params: [nick, text]} = message),
    do: {:welcome, %{nick: nick, text: text, message: message}}

  defp event_for(%Message{command: "002", params: [_nick, text]} = message),
    do: {:your_host, %{text: text, message: message}}

  defp event_for(%Message{command: "003", params: [_nick, text]} = message),
    do: {:server_created, %{text: text, message: message}}

  defp event_for(
         %Message{
           command: "004",
           params: [_nick, server, version, user_modes, channel_modes | rest]
         } = message
       ),
       do:
         {:server_info,
          %{
            server: server,
            version: version,
            user_modes: user_modes,
            channel_modes: channel_modes,
            params: rest,
            message: message
          }}

  defp event_for(%Message{command: "010", params: [_me, hostname, port, text]} = message),
    do: {:bounce, %{hostname: hostname, port: port, text: text, message: message}}

  defp event_for(%Message{command: "321", params: params} = message),
    do: {:list_start, %{params: params, message: message}}

  defp event_for(%Message{command: "322", params: [_me, channel, visible, topic]} = message),
    do: {:list_entry, %{channel: channel, visible: visible, topic: topic, message: message}}

  defp event_for(%Message{command: "323", params: params} = message),
    do: {:list_end, %{params: params, message: message}}

  defp event_for(%Message{command: "375", params: [_me, text]} = message),
    do: {:motd_start, %{text: text, message: message}}

  defp event_for(%Message{command: "372", params: [_me, text]} = message),
    do: {:motd, %{text: text, message: message}}

  defp event_for(%Message{command: "376", params: [_me, text]} = message),
    do: {:motd_end, %{text: text, message: message}}

  defp event_for(%Message{command: "422", params: [_me, text]} = message),
    do: {:motd_missing, %{text: text, message: message}}

  defp event_for(%Message{command: "256", params: [_me, server, text]} = message),
    do: {:admin_start, %{server: server, text: text, message: message}}

  defp event_for(%Message{command: "257", params: [_me, text]} = message),
    do: {:admin_location, %{line: 1, text: text, message: message}}

  defp event_for(%Message{command: "258", params: [_me, text]} = message),
    do: {:admin_location, %{line: 2, text: text, message: message}}

  defp event_for(%Message{command: "259", params: [_me, text]} = message),
    do: {:admin_email, %{text: text, message: message}}

  defp event_for(%Message{command: command, params: params} = message)
       when command in ["251", "252", "253", "254", "255", "265", "266"] do
    {:lusers, %{code: command, params: params, text: List.last(params), message: message}}
  end

  defp event_for(%Message{command: "263", params: [_me, command, text]} = message),
    do: {:try_again, %{command: command, text: text, message: message}}

  defp event_for(%Message{command: "391", params: [_me, server, time]} = message),
    do: {:time, %{server: server, time: time, message: message}}

  defp event_for(%Message{command: "371", params: [_me, text]} = message),
    do: {:info, %{text: text, message: message}}

  defp event_for(%Message{command: "374", params: [_me, text]} = message),
    do: {:info_end, %{text: text, message: message}}

  defp event_for(%Message{command: "364", params: [_me, mask, server, hopcount, info]} = message),
    do: {:links, %{mask: mask, server: server, hopcount: hopcount, info: info, message: message}}

  defp event_for(%Message{command: "365", params: [_me, mask, text]} = message),
    do: {:links_end, %{mask: mask, text: text, message: message}}

  defp event_for(%Message{command: "302", params: [_me, replies]} = message),
    do: {:userhost, %{replies: String.split(replies, " ", trim: true), message: message}}

  defp event_for(%Message{command: "303", params: [_me, nicks]} = message),
    do: {:ison, %{nicks: String.split(nicks, " ", trim: true), message: message}}

  defp event_for(%Message{command: "300", params: params} = message),
    do: {:none, %{params: params, text: List.last(params), message: message}}

  defp event_for(%Message{command: "301", params: [_me, nick, text]} = message),
    do: {:away_reply, %{nick: nick, text: text, message: message}}

  defp event_for(%Message{command: "305", params: [_me, text]} = message),
    do: {:unaway, %{text: text, message: message}}

  defp event_for(%Message{command: "306", params: [_me, text]} = message),
    do: {:now_away, %{text: text, message: message}}

  defp event_for(
         %Message{command: "234", params: [_me, name, server, mask, type, hopcount, info]} =
           message
       ),
       do:
         {:servlist,
          %{
            name: name,
            server: server,
            mask: mask,
            type: type,
            hopcount: hopcount,
            info: info,
            message: message
          }}

  defp event_for(%Message{command: "235", params: [_me, mask, type, text]} = message),
    do: {:servlist_end, %{mask: mask, type: type, text: text, message: message}}

  defp event_for(%Message{command: "211", params: [_me | params]} = message),
    do: {:stats_linkinfo, %{params: params, text: List.last(params), message: message}}

  defp event_for(%Message{command: "242", params: [_me, text]} = message),
    do: {:stats_uptime, %{text: text, message: message}}

  defp event_for(%Message{command: command, params: [_me | params]} = message)
       when command in ["213", "215", "216", "241", "243", "244"] do
    {:stats_line, %{code: command, params: params, text: List.last(params), message: message}}
  end

  defp event_for(%Message{command: command, params: [_me | params]} = message)
       when command in [
              "200",
              "201",
              "202",
              "203",
              "204",
              "205",
              "206",
              "207",
              "208",
              "209",
              "210"
            ] do
    {:trace, %{code: command, params: params, text: List.last(params), message: message}}
  end

  defp event_for(%Message{command: "262", params: [_me, target, text]} = message),
    do: {:trace_end, %{target: target, text: text, message: message}}

  defp event_for(%Message{command: "392", params: [_me, text]} = message),
    do: {:users_start, %{text: text, message: message}}

  defp event_for(%Message{command: "393", params: [_me, text]} = message),
    do: {:users, %{text: text, message: message}}

  defp event_for(%Message{command: "394", params: [_me, text]} = message),
    do: {:users_end, %{text: text, message: message}}

  defp event_for(%Message{command: "395", params: [_me, text]} = message),
    do: {:users_disabled, %{text: text, message: message}}

  defp event_for(%Message{command: "381", params: [_me, text]} = message),
    do: {:youre_oper, %{text: text, message: message}}

  defp event_for(%Message{command: "382", params: [_me, config_file, text]} = message),
    do: {:rehashing, %{config_file: config_file, text: text, message: message}}

  defp event_for(%Message{command: "670", params: [_me, text]} = message),
    do: {:starttls, %{text: text, message: message}}

  defp event_for(%Message{command: "691", params: [_me, text]} = message),
    do: {:starttls_failed, %{text: text, message: message}}

  defp event_for(%Message{command: "351", params: [_me, version, server | rest]} = message),
    do:
      {:version,
       %{version: version, server: server, comments: List.first(rest), message: message}}

  defp event_for(%Message{command: "212", params: [_me, command, count | rest]} = message),
    do: {:stats_command, %{command: command, count: count, params: rest, message: message}}

  defp event_for(%Message{command: "219", params: [_me, query, text]} = message),
    do: {:stats_end, %{query: query, text: text, message: message}}

  defp event_for(%Message{command: "704", params: [_me, subject, text]} = message),
    do: {:help_start, %{subject: subject, text: text, message: message}}

  defp event_for(%Message{command: "705", params: [_me, subject, text]} = message),
    do: {:help, %{subject: subject, text: text, message: message}}

  defp event_for(%Message{command: "706", params: [_me, subject, text]} = message),
    do: {:help_end, %{subject: subject, text: text, message: message}}

  defp event_for(%Message{command: "221", params: [_me, modes]} = message),
    do: {:user_mode, %{modes: modes, message: message}}

  defp event_for(%Message{command: "324", params: [_me, channel, modes | params]} = message),
    do: {:channel_mode, %{channel: channel, modes: modes, params: params, message: message}}

  defp event_for(%Message{command: "329", params: [_me, channel, created_at]} = message),
    do: {:channel_created, %{channel: channel, created_at: created_at, message: message}}

  defp event_for(%Message{command: "341", params: [_me, nick, channel]} = message),
    do: {:inviting, %{nick: nick, channel: channel, message: message}}

  defp event_for(%Message{command: "342", params: [_me, user, text]} = message),
    do: {:summoning, %{user: user, text: text, message: message}}

  defp event_for(%Message{command: "336", params: [_me, channel, mask]} = message),
    do: {:invite_list, %{channel: channel, mask: mask, message: message}}

  defp event_for(%Message{command: "337", params: [_me, channel, text]} = message),
    do: {:invite_list_end, %{channel: channel, text: text, message: message}}

  defp event_for(%Message{command: "367", params: [_me, channel, mask | rest]} = message),
    do: {:ban_list, %{channel: channel, mask: mask, params: rest, message: message}}

  defp event_for(%Message{command: "368", params: [_me, channel, text]} = message),
    do: {:ban_list_end, %{channel: channel, text: text, message: message}}

  defp event_for(%Message{command: "346", params: [_me, channel, mask | rest]} = message),
    do: {:invite_exception_list, %{channel: channel, mask: mask, params: rest, message: message}}

  defp event_for(%Message{command: "347", params: [_me, channel, text]} = message),
    do: {:invite_exception_list_end, %{channel: channel, text: text, message: message}}

  defp event_for(%Message{command: "348", params: [_me, channel, mask | rest]} = message),
    do: {:exception_list, %{channel: channel, mask: mask, params: rest, message: message}}

  defp event_for(%Message{command: "349", params: [_me, channel, text]} = message),
    do: {:exception_list_end, %{channel: channel, text: text, message: message}}

  defp event_for(%Message{command: "331", params: [_me, channel, text]} = message),
    do: {:topic_empty, %{channel: channel, text: text, message: message}}

  defp event_for(%Message{command: "332", params: [_me, channel, topic]} = message),
    do: {:topic_reply, %{channel: channel, topic: topic, message: message}}

  defp event_for(%Message{command: "333", params: [_me, channel, setter, set_at]} = message),
    do: {:topic_who_time, %{channel: channel, setter: setter, set_at: set_at, message: message}}

  defp event_for(%Message{command: command, params: [_me | params]} = message)
       when command in [
              "400",
              "401",
              "402",
              "403",
              "404",
              "405",
              "406",
              "407",
              "408",
              "409",
              "411",
              "412",
              "413",
              "414",
              "415",
              "417",
              "421",
              "423",
              "424",
              "431",
              "432",
              "436",
              "437",
              "441",
              "442",
              "443",
              "444",
              "445",
              "446",
              "451",
              "461",
              "462",
              "463",
              "464",
              "465",
              "466",
              "467",
              "471",
              "472",
              "473",
              "474",
              "475",
              "476",
              "477",
              "478",
              "481",
              "482",
              "483",
              "484",
              "485",
              "491",
              "492",
              "501",
              "502",
              "524",
              "525",
              "696",
              "723"
            ] do
    {:irc_error,
     %{
       code: command,
       target: error_target(params),
       reason: List.last(params),
       params: params,
       message: message
     }}
  end

  defp event_for(%Message{command: command, params: params} = message)
       when command in ["FAIL", "WARN", "NOTE"] do
    case StandardReply.parse(command, params) do
      {:ok, reply} -> {:standard_reply, Map.put(reply, :message, message)}
      {:error, reason} -> {:standard_reply_error, %{reason: reason, message: message}}
    end
  end

  defp event_for(message), do: {:raw, message}

  defp dcc_from_ctcp({:ok, ctcp}) do
    case DCC.parse(ctcp) do
      {:ok, dcc} -> dcc
      {:error, :not_dcc} -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp dcc_from_ctcp(_ctcp), do: nil

  defp whois_event("311", params), do: {:whois_user, Whois.parse_user(params)}
  defp whois_event("314", params), do: {:whowas_user, Whois.parse_whowas_user(params)}
  defp whois_event("312", params), do: {:whois_server, Whois.parse_server(params)}
  defp whois_event("313", params), do: {:whois_operator, Whois.parse_operator(params)}
  defp whois_event("276", params), do: {:whois_certfp, Whois.parse_certfp(params)}

  defp whois_event("307", params),
    do: {:whois_registered_nick, Whois.parse_registered_nick(params)}

  defp whois_event("335", params), do: {:whois_bot, Whois.parse_bot(params)}
  defp whois_event("317", params), do: {:whois_idle, Whois.parse_idle(params)}
  defp whois_event("319", params), do: {:whois_channels, Whois.parse_channels(params)}
  defp whois_event("330", params), do: {:whois_account, Whois.parse_account(params)}
  defp whois_event("320", params), do: {:whois_special, Whois.parse_special(params)}
  defp whois_event("338", params), do: {:whois_actual_host, Whois.parse_actual_host(params)}
  defp whois_event("378", params), do: {:whois_host, Whois.parse_host(params)}
  defp whois_event("379", params), do: {:whois_modes, Whois.parse_modes(params)}
  defp whois_event("671", params), do: {:whois_secure, Whois.parse_secure(params)}
  defp whois_event("318", params), do: {:whois_end, Whois.parse_end(params)}
  defp whois_event("369", params), do: {:whowas_end, Whois.parse_whowas_end(params)}

  defp error_target([target, _reason | _rest]), do: target
  defp error_target(_params), do: nil

  defp handle_batch(%Message{params: params} = message, state) do
    case Batch.parse(params) do
      {:ok, %{direction: :start, ref: ref, type: type, params: batch_params}} ->
        batch = %{type: type, params: batch_params, message: message}
        state = %{state | active_batches: Map.put(state.active_batches, ref, batch)}
        state = maybe_start_multiline(state, ref, batch)
        state = maybe_start_labeled_response_batch(state, ref, batch)
        state = maybe_start_isupport_batch(state, ref, batch)
        state = maybe_start_metadata_batch(state, ref, batch)
        state = maybe_start_net_batch(state, ref, batch)
        state = emit(state, {:batch_start, Map.put(batch, :ref, ref)})
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %{direction: :end, ref: ref}} ->
        {batch, active_batches} = Map.pop(state.active_batches, ref)

        if is_nil(batch) do
          state =
            emit(state, {:batch_error, %{reason: :unknown_batch, ref: ref, message: message}})

          state = emit(state, {:message, message})
          {:noreply, state}
        else
          state = %{state | active_batches: active_batches}
          state = maybe_emit_multiline(state, ref, batch)
          state = maybe_emit_labeled_response_batch(state, ref, batch)
          state = maybe_emit_isupport_batch(state, ref, batch)
          state = maybe_emit_metadata_batch(state, ref, batch)
          state = maybe_emit_net_batch(state, ref, batch)
          state = emit(state, {:batch_end, %{ref: ref, batch: batch}})
          state = emit(state, {:message, message})
          {:noreply, state}
        end

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
      |> maybe_emit_typing(event)
      |> maybe_emit_reaction(event)
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

  defp maybe_emit_typing(
         state,
         {:tagmsg,
          %{
            source: source,
            raw_source: raw_source,
            nick: nick,
            target: target,
            tags: %{"+typing" => status},
            message: message
          }}
       ) do
    emit(state, {
      :typing,
      %{
        source: source,
        raw_source: raw_source,
        nick: nick,
        target: target,
        status: parse_typing_status(status),
        raw_status: status,
        message: message
      }
    })
  end

  defp maybe_emit_typing(state, _event), do: state

  defp maybe_emit_reaction(
         state,
         {:tagmsg,
          %{
            source: source,
            raw_source: raw_source,
            nick: nick,
            target: target,
            tags: tags,
            message: message
          }}
       ) do
    case reaction_from_tags(tags) do
      nil ->
        state

      %{action: action, reaction: reaction, reply_to_msgid: reply_to_msgid} ->
        emit(state, {
          :reaction,
          %{
            source: source,
            raw_source: raw_source,
            nick: nick,
            target: target,
            action: action,
            reaction: reaction,
            reply_to_msgid: reply_to_msgid,
            message: message
          }
        })
    end
  end

  defp maybe_emit_reaction(state, _event), do: state

  defp maybe_emit_labeled_response(state, event, message) do
    state = maybe_ack_labeled_request(state, event)

    case Tags.label(message) do
      nil ->
        state

      label ->
        state
        |> emit({:labeled_response, %{label: label, event: event, message: message}})
        |> maybe_complete_labeled_request(event, label)
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

  defp maybe_complete_labeled_request(state, {:ack, _payload}, _label), do: state

  defp maybe_complete_labeled_request(state, _event, label),
    do: complete_labeled_request(state, label, :single)

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
        state = maybe_collect_isupport_batch(state, ref, event)
        state = maybe_collect_metadata_batch(state, ref, event)
        state = maybe_collect_net_batch(state, ref, event)

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

  defp maybe_start_isupport_batch(state, ref, %{type: "draft/isupport"}) do
    %{state | isupport_batches: Map.put(state.isupport_batches, ref, %{entries: []})}
  end

  defp maybe_start_isupport_batch(state, _ref, _batch), do: state

  defp maybe_collect_isupport_batch(state, ref, {:isupport, tokens}) do
    case Map.fetch(state.isupport_batches, ref) do
      {:ok, batch} ->
        batch = %{batch | entries: batch.entries ++ [tokens]}
        %{state | isupport_batches: Map.put(state.isupport_batches, ref, batch)}

      :error ->
        state
    end
  end

  defp maybe_collect_isupport_batch(state, _ref, _event), do: state

  defp maybe_emit_isupport_batch(state, ref, %{type: "draft/isupport"}) do
    {batch, isupport_batches} = Map.pop(state.isupport_batches, ref)
    state = %{state | isupport_batches: isupport_batches}

    case batch do
      %{entries: entries} ->
        emit(
          state,
          {:isupport_batch,
           %{ref: ref, tokens: merge_isupport_entries(entries), entries: entries}}
        )

      _ ->
        state
    end
  end

  defp maybe_emit_isupport_batch(state, ref, _batch) do
    %{state | isupport_batches: Map.delete(state.isupport_batches, ref)}
  end

  defp merge_isupport_entries(entries), do: Enum.reduce(entries, %{}, &Map.merge(&2, &1))

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

  defp maybe_start_net_batch(state, ref, %{type: type, params: [server_a, server_b]})
       when type in ["netsplit", "netjoin"] do
    net_batch = %{type: type, from_server: server_a, to_server: server_b, events: []}
    %{state | net_batches: Map.put(state.net_batches, ref, net_batch)}
  end

  defp maybe_start_net_batch(state, _ref, _batch), do: state

  defp maybe_collect_net_batch(state, ref, event) do
    case Map.fetch(state.net_batches, ref) do
      {:ok, batch} ->
        batch = %{batch | events: batch.events ++ [event]}
        %{state | net_batches: Map.put(state.net_batches, ref, batch)}

      :error ->
        state
    end
  end

  defp maybe_emit_net_batch(state, ref, %{type: type}) when type in ["netsplit", "netjoin"] do
    {batch, net_batches} = Map.pop(state.net_batches, ref)
    state = %{state | net_batches: net_batches}

    case batch do
      %{type: "netsplit"} = batch -> emit(state, {:netsplit, Map.put(batch, :ref, ref)})
      %{type: "netjoin"} = batch -> emit(state, {:netjoin, Map.put(batch, :ref, ref)})
      _ -> state
    end
  end

  defp maybe_emit_net_batch(state, ref, _batch) do
    %{state | net_batches: Map.delete(state.net_batches, ref)}
  end

  defp send_message(%{transport: nil}, _command, _params), do: {:error, :not_connected}

  defp send_message(state, command, params) do
    send_message(state, %Message{command: command, params: params})
  end

  defp send_message(%{transport: nil}, %Message{}), do: {:error, :not_connected}

  defp send_message(state, %Message{} = message) do
    with :ok <- validate_outbound_command(state, message),
         :ok <- validate_utf8_only(state, message),
         :ok <- validate_outbound_tags(state, message) do
      line = Message.serialize(message)

      if Message.valid_wire_size?(line) do
        case state.transport do
          :ssl -> :ssl.send(state.socket, line)
          :gen_tcp -> :gen_tcp.send(state.socket, line)
        end
      else
        {:error, :line_too_long}
      end
    end
  end

  defp validate_outbound_command(state, %Message{command: "REDACT"}) do
    with :ok <- require_active_cap(state, "draft/message-redaction") do
      require_active_cap(state, "message-tags")
    end
  end

  defp validate_outbound_command(state, %Message{command: "MARKREAD"}),
    do: require_active_cap(state, "draft/read-marker")

  defp validate_outbound_command(state, %Message{command: "RENAME"}),
    do: require_active_cap(state, "draft/channel-rename")

  defp validate_outbound_command(state, %Message{command: "METADATA"}),
    do: require_active_cap(state, "metadata")

  defp validate_outbound_command(state, %Message{command: "CHATHISTORY"}),
    do: require_active_cap(state, "draft/chathistory")

  defp validate_outbound_command(state, %Message{command: command})
       when command in ["REGISTER", "VERIFY"],
       do: require_active_cap(state, "draft/account-registration")

  defp validate_outbound_command(state, %Message{command: "AWAY", params: ["*"]}),
    do: require_active_cap(state, "draft/pre-away")

  defp validate_outbound_command(_state, _message), do: :ok

  defp validate_utf8_only(%{isupport: %{"UTF8ONLY" => true}}, %Message{
         command: command,
         params: params
       }) do
    if Enum.all?(params, &String.valid?/1) do
      :ok
    else
      {:error, {:invalid_utf8, command}}
    end
  end

  defp validate_utf8_only(_state, _message), do: :ok

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

  defp ensure_caps_available(_state, []), do: {:error, :missing_capabilities}

  defp ensure_caps_available(state, caps) do
    case Enum.reject(caps, &Map.has_key?(state.available_caps, &1)) do
      [] -> :ok
      missing -> {:error, {:capabilities_not_available, missing}}
    end
  end

  defp require_client_batch_cap(state, opts) do
    case Keyword.get(opts, :required_cap) || Keyword.get(opts, :capability) do
      cap when is_binary(cap) -> require_active_cap(state, cap)
      nil -> {:error, :missing_client_batch_capability}
    end
  end

  defp maybe_include_sasl(caps, %{sasl: nil}), do: caps

  defp maybe_include_sasl(caps, state) do
    if available_sasl_mechanisms(state) == [] do
      caps
    else
      ["sasl" | caps]
    end
  end

  defp normalize_sasl(nil), do: []
  defp normalize_sasl({:plain, _username, _password} = mechanism), do: [mechanism]
  defp normalize_sasl({:external, _authzid} = mechanism), do: [mechanism]
  defp normalize_sasl({:scram_sha_256, _username, _password} = mechanism), do: [mechanism]

  defp normalize_sasl({:scram_sha_256, _username, _password, opts} = mechanism)
       when is_list(opts),
       do: [mechanism]

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

  defp should_start_sasl?(state, acked_caps),
    do: available_sasl_mechanisms(state) != [] and "sasl" in acked_caps

  defp send_sasl_start(state) do
    send_message(state, "AUTHENTICATE", [current_sasl_mechanism_name(state)])
  end

  defp parse_sasl_mechanisms(mechanisms) do
    String.split(mechanisms, ",", trim: true)
  end

  defp parse_typing_status("active"), do: :active
  defp parse_typing_status("paused"), do: :paused
  defp parse_typing_status("done"), do: :done
  defp parse_typing_status(status), do: {:unknown, status}

  defp reaction_tagmsg(_client, _target, "", _tag, _reaction), do: {:error, :missing_reply_msgid}
  defp reaction_tagmsg(_client, _target, nil, _tag, _reaction), do: {:error, :missing_reply_msgid}

  defp reaction_tagmsg(_client, _target, _reply_to_msgid, _tag, ""),
    do: {:error, :missing_reaction}

  defp reaction_tagmsg(_client, _target, _reply_to_msgid, _tag, nil),
    do: {:error, :missing_reaction}

  defp reaction_tagmsg(client, target, reply_to_msgid, tag, reaction),
    do: tagmsg(client, target, %{tag => reaction, "+reply" => reply_to_msgid})

  defp context_message(_client, _command, _target, "", _body),
    do: {:error, :missing_channel_context}

  defp context_message(_client, _command, _target, nil, _body),
    do: {:error, :missing_channel_context}

  defp context_message(client, command, target, channel_context, body) do
    GenServer.call(
      client,
      {:send,
       %Message{
         command: command,
         params: [target, body],
         tags: %{"+draft/channel-context" => channel_context}
       }}
    )
  end

  defp reaction_from_tags(%{
         "+draft/react" => _reaction,
         "+draft/unreact" => _unreaction
       }),
       do: nil

  defp reaction_from_tags(%{"+draft/react" => reaction, "+reply" => reply_to_msgid}) do
    %{action: :react, reaction: reaction, reply_to_msgid: reply_to_msgid}
  end

  defp reaction_from_tags(%{"+draft/unreact" => reaction, "+reply" => reply_to_msgid}) do
    %{action: :unreact, reaction: reaction, reply_to_msgid: reply_to_msgid}
  end

  defp reaction_from_tags(_tags), do: nil

  defp select_first_sasl_mechanism(state),
    do: %{state | sasl_mechanisms: available_sasl_mechanisms(state), sasl_index: 0}

  defp available_sasl_mechanisms(%{sasl_mechanisms: mechanisms, available_caps: available_caps}) do
    case Map.get(available_caps, "sasl") do
      value when is_binary(value) ->
        advertised = value |> parse_sasl_mechanisms() |> MapSet.new()
        Enum.filter(mechanisms, &(sasl_mechanism_name(&1) in advertised))

      true ->
        mechanisms

      _value ->
        []
    end
  end

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
  defp sasl_mechanism_name({:scram_sha_256, _username, _password}), do: "SCRAM-SHA-256"
  defp sasl_mechanism_name({:scram_sha_256, _username, _password, _opts}), do: "SCRAM-SHA-256"
  defp sasl_mechanism_name(nil), do: nil

  defp sasl_mechanism_atom({:plain, _username, _password}), do: :plain
  defp sasl_mechanism_atom({:external, _authzid}), do: :external
  defp sasl_mechanism_atom({:scram_sha_256, _username, _password}), do: :scram_sha_256
  defp sasl_mechanism_atom({:scram_sha_256, _username, _password, _opts}), do: :scram_sha_256
  defp sasl_mechanism_atom(nil), do: nil

  defp handle_sasl_authenticate(state, "+"), do: send_sasl_initial_response(state)

  defp handle_sasl_authenticate(%{sasl_scram: %{phase: :server_first}} = state, payload) do
    with {:ok, server_first} <- Base.decode64(payload),
         {:ok, final} <-
           SASL.scram_sha256_client_final(
             state.sasl_scram.client_first_bare,
             server_first,
             state.sasl_scram.password
           ) do
      final.payload
      |> SASL.authenticate_chunks()
      |> Enum.each(&send_message(state, "AUTHENTICATE", [&1]))

      %{
        state
        | sasl_scram:
            Map.merge(state.sasl_scram, %{
              phase: :server_final,
              server_signature: final.server_signature
            })
      }
    else
      :error ->
        emit(state, {:sasl_scram_error, %{reason: :invalid_base64}})

      {:error, reason} ->
        emit(state, {:sasl_scram_error, %{reason: reason}})
    end
  end

  defp handle_sasl_authenticate(%{sasl_scram: %{phase: :server_final}} = state, payload) do
    with {:ok, server_final} <- Base.decode64(payload),
         :ok <-
           SASL.verify_scram_sha256_server_final(
             server_final,
             state.sasl_scram.server_signature
           ) do
      %{state | sasl_scram: %{state.sasl_scram | phase: :complete}}
    else
      :error ->
        emit(state, {:sasl_scram_error, %{reason: :invalid_base64}})

      {:error, reason} ->
        emit(state, {:sasl_scram_error, %{reason: reason}})
    end
  end

  defp handle_sasl_authenticate(state, _payload), do: state

  defp send_sasl_initial_response(%{sasl_mechanisms: mechanisms, sasl_index: index} = state) do
    case Enum.at(mechanisms, index) do
      {:plain, username, password} ->
        username
        |> SASL.plain_payload(password)
        |> SASL.authenticate_chunks()
        |> Enum.each(&send_message(state, "AUTHENTICATE", [&1]))

        state

      {:external, authzid} ->
        authzid
        |> SASL.external_payload()
        |> SASL.authenticate_chunks()
        |> Enum.each(&send_message(state, "AUTHENTICATE", [&1]))

        state

      {:scram_sha_256, username, password} ->
        send_sasl_scram_client_first(state, username, password, [])

      {:scram_sha_256, username, password, opts} ->
        send_sasl_scram_client_first(state, username, password, opts)

      nil ->
        state
    end
  end

  defp send_sasl_initial_response(state), do: state

  defp send_sasl_scram_client_first(state, username, password, opts) do
    nonce = Keyword.get_lazy(opts, :nonce, &scram_nonce/0)
    first = SASL.scram_sha256_client_first(username, nonce)

    first.payload
    |> SASL.authenticate_chunks()
    |> Enum.each(&send_message(state, "AUTHENTICATE", [&1]))

    %{
      state
      | sasl_scram: %{
          phase: :server_first,
          client_first_bare: first.bare,
          password: password
        }
    }
  end

  defp sasl_scram_verified_or_unused?(%{sasl_scram: nil}), do: true
  defp sasl_scram_verified_or_unused?(%{sasl_scram: %{phase: :complete}}), do: true
  defp sasl_scram_verified_or_unused?(_state), do: false

  defp scram_nonce do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

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

  defp normalize_client_batch_messages(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn
      %Message{} = message, {:ok, acc} ->
        {:cont, {:ok, [message | acc]}}

      {command, params}, {:ok, acc} when is_binary(command) and is_list(params) ->
        {:cont, {:ok, [%Message{command: command, params: params} | acc]}}

      {command, params, tags}, {:ok, acc}
      when is_binary(command) and is_list(params) and is_map(tags) ->
        {:cont, {:ok, [%Message{command: command, params: params, tags: tags} | acc]}}

      _invalid, _acc ->
        {:halt, {:error, :invalid_client_batch_message}}
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp normalize_client_batch_messages(_messages), do: {:error, :invalid_client_batch_message}

  defp validate_client_batch_messages(messages) do
    cond do
      Enum.any?(messages, &(String.upcase(&1.command) == "BATCH")) ->
        {:error, :nested_client_batch}

      Enum.any?(messages, &Map.has_key?(&1.tags, "batch")) ->
        {:error, :reserved_client_batch_tag}

      true ->
        :ok
    end
  end

  defp send_client_batch(state, reference, type, params, messages) do
    reference = to_string(reference)
    type = to_string(type)
    params = Enum.map(params, &to_string/1)

    with :ok <- send_message(state, "BATCH", ["+" <> reference, type | params]) do
      case send_client_batch_messages(state, messages, reference) do
        :ok ->
          send_message(state, "BATCH", ["-" <> reference])

        error ->
          _ = send_message(state, "BATCH", ["-" <> reference])
          error
      end
    end
  end

  defp send_client_batch_messages(state, messages, reference) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      message = %{message | tags: Map.put(message.tags, "batch", reference)}

      case send_message(state, message) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
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

  defp parse_markread_timestamp("*"), do: {:ok, nil}

  defp parse_markread_timestamp("timestamp=" <> timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_markread_timestamp(_timestamp), do: {:error, :invalid_markread_timestamp}

  defp parse_account_registration_status("SUCCESS"), do: :success
  defp parse_account_registration_status("VERIFICATION_REQUIRED"), do: :verification_required
  defp parse_account_registration_status(status), do: {:unknown, status}

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
