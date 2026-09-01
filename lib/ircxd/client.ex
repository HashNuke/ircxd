defmodule Ircxd.Client do
  @moduledoc """
  Provides a supervised IRC client and command functions.

  Use `start_link/1` to configure a connection. Use the command functions only
  after the client emits the `:registered` event.
  """

  use GenServer

  alias Ircxd.Batch
  alias Ircxd.AccountExtban
  alias Ircxd.ChatHistory
  alias Ircxd.ClientCommand
  alias Ircxd.Client.Info
  alias Ircxd.Client.Event
  alias Ircxd.Client.Resume
  alias Ircxd.Client.Transport.Socket, as: SocketTransport
  alias Ircxd.ClientTagDeny
  alias Ircxd.CTCP
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
  alias Ircxd.UserHost
  alias Ircxd.WebIRC
  alias Ircxd.Who
  alias Ircxd.Whois

  @doc """
  Starts a client process and schedules a connection attempt.

  This function accepts these options:

    * `:host` - Required server host.
    * `:nick` - Required initial nickname.
    * `:port` - Server port. The default is `6697` for TLS or `6667` for TCP.
    * `:tls` - Enables implicit TLS. The default is `false`.
    * `:sni` - Sets the TLS server name. The default is `:host`.
    * `:tls_options` - Adds options for `:ssl.connect/4`.
    * `:username` - Sets the registration username. The default is `:nick`.
    * `:realname` - Sets the registration real name. The default is `:nick`.
    * `:nick_retry_fun` - Sets the nickname-collision function.
    * `:name` - Registers the client process with a name.
    * `:caps` - Sets the IRCv3 capabilities to request.
    * `:notify` - Sets the process that receives `{:ircxd, event}` messages.
    * `:adapter` - Sets an `{adapter_module, init_arg}` pair.
    * `:events` - Sets `:legacy`, `:envelope`, or `:both` event delivery.
    * `:additional_error_numerics` - Opts into treating selected three-digit
      vendor numerics as generic `:irc_error` events. The default is `[]`, so
      numerics outside Ircxd's built-in catalog continue to emit `:raw`.
    * `:reconnect` - Sets `false`, `true`, or a list with `:max_attempts` and
      `:delay`.
    * `:password` - Sets the server password for registration.
    * `:sasl` - Sets one SASL mechanism or an ordered mechanism list. A SCRAM
      mechanism can use `:nonce` for a fixed client nonce.
    * `:sasl_failure` - Sets `:continue` or `:abort`. The default is `:continue`.
    * `:allow_insecure_auth` - Permits credentials on TCP. The default is `false`.
    * `:webirc` - Sets `:password`, `:gateway`, `:hostname`, `:ip`, and optional
      WebIRC `:options`.
    * `:msgid_dedupe` - Sets `false` or `:mark` for message-ID duplicates.
    * `:server_time_order` - Sets `false`, `:manual`, or a list with
      `:flush_after`.
    * `:resume_binding` - Sets an optional non-secret binary generation token. Rotate it when
      credentials or security material change so a retained transport checkpoint is rejected.
    * `:transport_adapter` - Sets an optional `{Ircxd.Client.Transport, init_arg}` pair. Existing
      callers use `Ircxd.Client.Transport.Socket`, which preserves the built-in TCP/TLS behavior.

  The process connects asynchronously. A successful return does not mean that
  IRC registration is complete.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Returns a child specification with the same options as `start_link/1`."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Sends a `CAP REQ` command for one or more capabilities."
  def request_capabilities(client, caps) do
    GenServer.call(client, {:request_caps, List.wrap(caps)})
  end

  @doc "Sends a `CAP REQ` command that disables one or more capabilities."
  def disable_capabilities(client, caps) do
    GenServer.call(client, {:disable_caps, List.wrap(caps)})
  end

  @doc "Sends a `CAP LIST` command."
  def cap_list(client), do: GenServer.call(client, :cap_list)

  @doc "Returns the cached, secret-free connection state."
  def connection_info(client), do: GenServer.call(client, :connection_info)

  @doc "Returns `true` if `nick` identifies the current client."
  def self_nick?(client, nick), do: GenServer.call(client, {:self_nick?, nick})

  @doc "Compares two identifiers with the negotiated IRC casemapping."
  def same_identifier?(client, left, right),
    do: GenServer.call(client, {:same_identifier?, left, right})

  @doc "Sends a `PASS` command."
  def pass(client, password), do: GenServer.call(client, {:send, "PASS", [password]})

  @doc "Sends a `NICK` command."
  def nick(client, nick), do: GenServer.call(client, {:send, "NICK", [nick]})

  @doc "Sends a `JOIN` command."
  def join(client, channel), do: GenServer.call(client, {:send, "JOIN", [channel]})

  @doc "Sends a `NAMES` command."
  def names(client, target), do: GenServer.call(client, {:send, "NAMES", [target]})

  @doc "Sends a `LIST` command for optional channels and a server."
  def list(client, channels \\ nil, server \\ nil)
  def list(client, nil, nil), do: GenServer.call(client, {:send, "LIST", []})

  def list(client, channels, nil),
    do: GenServer.call(client, {:send, "LIST", [join_targets(channels)]})

  def list(client, channels, server),
    do: GenServer.call(client, {:send, "LIST", [join_targets(channels), server]})

  @doc "Sends an `INVITE` command."
  def invite(client, nick, channel),
    do: GenServer.call(client, {:send, "INVITE", [nick, channel]})

  @doc "Sends a `PART` command."
  def part(client, channel, reason \\ ""),
    do: GenServer.call(client, {:send, "PART", [channel, reason]})

  @doc "Gets or sets a channel topic with a `TOPIC` command."
  def topic(client, channel, topic \\ nil)
  def topic(client, channel, nil), do: GenServer.call(client, {:send, "TOPIC", [channel]})

  def topic(client, channel, topic),
    do: GenServer.call(client, {:send, "TOPIC", [channel, topic]})

  @doc "Sets IRC modes on a target."
  def mode(client, target, modes, params \\ []),
    do: GenServer.call(client, {:send, "MODE", [target, modes | params]})

  @doc "Gets the IRC modes for a target."
  def mode_query(client, target), do: GenServer.call(client, {:send, "MODE", [target]})

  @doc "Gets the IRC modes for a channel."
  def channel_modes(client, channel), do: mode_query(client, channel)

  @doc "Gets the IRC modes for a user."
  def user_modes(client, nick), do: mode_query(client, nick)

  @doc "Sends a `KICK` command."
  def kick(client, channel, nick, reason \\ ""),
    do: GenServer.call(client, {:send, "KICK", [channel, nick, reason]})

  @doc "Sends a `PRIVMSG` command."
  def privmsg(client, target, body),
    do: GenServer.call(client, {:send, "PRIVMSG", [target, body]})

  @doc "Sends a tagged `PRIVMSG` command."
  def privmsg(client, target, body, tags) when is_map(tags),
    do:
      GenServer.call(
        client,
        {:send, %Message{command: "PRIVMSG", params: [target, body], tags: tags}}
      )

  @doc "Sends a CTCP `ACTION` message."
  def action(client, target, body), do: privmsg(client, target, CTCP.encode("ACTION", body))

  @doc "Sends a reply with the `+reply` client tag."
  def reply(client, target, body, reply_to_msgid),
    do: privmsg(client, target, body, %{"+reply" => reply_to_msgid})

  @doc "Sends a `PRIVMSG` command with a channel-context tag."
  def context_privmsg(client, target, channel_context, body),
    do: context_message(client, "PRIVMSG", target, channel_context, body)

  @doc "Sends a `NOTICE` command."
  def notice(client, target, body), do: GenServer.call(client, {:send, "NOTICE", [target, body]})

  @doc "Sends a tagged `NOTICE` command."
  def notice(client, target, body, tags) when is_map(tags),
    do:
      GenServer.call(
        client,
        {:send, %Message{command: "NOTICE", params: [target, body], tags: tags}}
      )

  @doc "Sends a `NOTICE` command with a channel-context tag."
  def context_notice(client, target, channel_context, body),
    do: context_message(client, "NOTICE", target, channel_context, body)

  @doc "Sends a `TAGMSG` command."
  def tagmsg(client, target, tags) when is_map(tags),
    do: GenServer.call(client, {:send, %Message{command: "TAGMSG", params: [target], tags: tags}})

  @doc "Sends an `:active`, `:paused`, or `:done` typing status."
  def typing(client, target, status) when status in [:active, :paused, :done],
    do: tagmsg(client, target, %{"+typing" => Atom.to_string(status)})

  def typing(_client, _target, _status), do: {:error, :invalid_typing_status}

  @doc "Adds a reaction to a message."
  def react(client, target, reply_to_msgid, reaction),
    do: reaction_tagmsg(client, target, reply_to_msgid, "+draft/react", reaction)

  @doc "Removes a reaction from a message."
  def unreact(client, target, reply_to_msgid, reaction),
    do: reaction_tagmsg(client, target, reply_to_msgid, "+draft/unreact", reaction)

  @doc "Sends a `REDACT` command with an optional reason."
  def redact(client, target, msgid, reason \\ nil)

  def redact(client, target, msgid, nil),
    do: GenServer.call(client, {:send, "REDACT", [target, msgid]})

  def redact(client, target, msgid, reason),
    do: GenServer.call(client, {:send, "REDACT", [target, msgid, reason]})

  @doc "Sends a `SETNAME` command."
  def setname(client, realname), do: GenServer.call(client, {:send, "SETNAME", [realname]})

  @doc "Sends a `RENAME` command with an optional reason."
  def rename(client, old_channel, new_channel, reason \\ nil)

  def rename(client, old_channel, new_channel, nil),
    do: GenServer.call(client, {:send, "RENAME", [old_channel, new_channel]})

  def rename(client, old_channel, new_channel, reason),
    do: GenServer.call(client, {:send, "RENAME", [old_channel, new_channel, reason]})

  @doc "Sends a `QUIT` command and suppresses automatic reconnection."
  def quit(client, reason \\ "leaving"), do: GenServer.call(client, {:send, "QUIT", [reason]})

  @doc "Starts a new connection attempt for a disconnected client."
  def reconnect(client), do: GenServer.call(client, :reconnect)

  @doc "Validates and sends an IRC command with parameters."
  def raw(client, command, params \\ []), do: GenServer.call(client, {:send, command, params})

  @doc "Gets the message of the day from the local server or a target server."
  def motd(client, target \\ nil)
  def motd(client, nil), do: GenServer.call(client, {:send, "MOTD", []})
  def motd(client, target), do: GenServer.call(client, {:send, "MOTD", [target]})

  @doc "Gets version information from the local server or a target server."
  def version(client, target \\ nil)
  def version(client, nil), do: GenServer.call(client, {:send, "VERSION", []})
  def version(client, target), do: GenServer.call(client, {:send, "VERSION", [target]})

  @doc "Gets administrator information from the local server or a target server."
  def admin(client, target \\ nil)
  def admin(client, nil), do: GenServer.call(client, {:send, "ADMIN", []})
  def admin(client, target), do: GenServer.call(client, {:send, "ADMIN", [target]})

  @doc "Gets user statistics with an optional mask and target server."
  def lusers(client, mask \\ nil, target \\ nil)
  def lusers(client, nil, nil), do: GenServer.call(client, {:send, "LUSERS", []})
  def lusers(client, mask, nil), do: GenServer.call(client, {:send, "LUSERS", [mask]})
  def lusers(client, mask, target), do: GenServer.call(client, {:send, "LUSERS", [mask, target]})

  @doc "Gets the time from the local server or a target server."
  def time(client, target \\ nil)
  def time(client, nil), do: GenServer.call(client, {:send, "TIME", []})
  def time(client, target), do: GenServer.call(client, {:send, "TIME", [target]})

  @doc "Gets server statistics for an optional query and target server."
  def stats(client, query \\ nil, target \\ nil)
  def stats(client, nil, nil), do: GenServer.call(client, {:send, "STATS", []})
  def stats(client, query, nil), do: GenServer.call(client, {:send, "STATS", [query]})
  def stats(client, query, target), do: GenServer.call(client, {:send, "STATS", [query, target]})

  @doc "Gets server help for an optional subject."
  def help(client, subject \\ nil)
  def help(client, nil), do: GenServer.call(client, {:send, "HELP", []})
  def help(client, subject), do: GenServer.call(client, {:send, "HELP", [subject]})

  @doc "Gets information from the local server or a target server."
  def info(client, target \\ nil)
  def info(client, nil), do: GenServer.call(client, {:send, "INFO", []})
  def info(client, target), do: GenServer.call(client, {:send, "INFO", [target]})

  @doc "Gets users that match a `WHO` mask and optional flags."
  def who(client, mask, options \\ nil)
  def who(client, mask, nil), do: GenServer.call(client, {:send, "WHO", [mask]})
  def who(client, mask, options), do: GenServer.call(client, {:send, "WHO", [mask, options]})
  @doc "Gets current information about a nickname."
  def whois(client, nick), do: GenServer.call(client, {:send, "WHOIS", [nick]})

  @doc "Gets historical information about a nickname."
  def whowas(client, nick, count \\ nil)
  def whowas(client, nick, nil), do: GenServer.call(client, {:send, "WHOWAS", [nick]})
  def whowas(client, nick, count), do: GenServer.call(client, {:send, "WHOWAS", [nick, count]})

  @doc "Gets server links with an optional remote server and mask."
  def links(client, remote_server \\ nil, mask \\ nil)
  def links(client, nil, nil), do: GenServer.call(client, {:send, "LINKS", []})

  def links(client, remote_server, nil),
    do: GenServer.call(client, {:send, "LINKS", [remote_server]})

  def links(client, remote_server, mask),
    do: GenServer.call(client, {:send, "LINKS", [remote_server, mask]})

  @doc "Gets host information for one or more nicknames."
  def userhost(client, nicks),
    do: GenServer.call(client, {:send, "USERHOST", List.wrap(nicks)})

  @doc "Gets the online status of one or more nicknames."
  def ison(client, nicks), do: GenServer.call(client, {:send, "ISON", List.wrap(nicks)})

  @doc "Sends a `WALLOPS` message."
  def wallops(client, message), do: GenServer.call(client, {:send, "WALLOPS", [message]})

  @doc "Sends operator credentials with an `OPER` command."
  def oper(client, name, password), do: GenServer.call(client, {:send, "OPER", [name, password]})

  @doc "Sends a `KILL` command."
  def kill(client, nick, comment),
    do: GenServer.call(client, {:send, "KILL", [nick, comment]})

  @doc "Sends an `SQUERY` command to a service."
  def squery(client, service, text),
    do: GenServer.call(client, {:send, "SQUERY", [service, text]})

  @doc "Gets route information for an optional target."
  def trace(client, target \\ nil)
  def trace(client, nil), do: GenServer.call(client, {:send, "TRACE", []})
  def trace(client, target), do: GenServer.call(client, {:send, "TRACE", [target]})

  @doc "Requests a server connection with a `CONNECT` command."
  def connect_server(client, target_server, port, remote_server \\ nil)

  def connect_server(client, target_server, port, nil),
    do: GenServer.call(client, {:send, "CONNECT", [target_server, to_string(port)]})

  def connect_server(client, target_server, port, remote_server),
    do:
      GenServer.call(client, {:send, "CONNECT", [target_server, to_string(port), remote_server]})

  @doc "Disconnects a server with an `SQUIT` command."
  def squit(client, server, comment),
    do: GenServer.call(client, {:send, "SQUIT", [server, comment]})

  @doc "Requests a server configuration reload."
  def rehash(client), do: GenServer.call(client, {:send, "REHASH", []})

  @doc "Requests a server restart."
  def restart(client), do: GenServer.call(client, {:send, "RESTART", []})

  @doc "Sends a `SUMMON` command."
  def summon(client, user, target \\ nil, channel \\ nil)
  def summon(client, user, nil, nil), do: GenServer.call(client, {:send, "SUMMON", [user]})

  def summon(client, user, target, nil),
    do: GenServer.call(client, {:send, "SUMMON", [user, target]})

  def summon(client, user, target, channel),
    do: GenServer.call(client, {:send, "SUMMON", [user, target, channel]})

  @doc "Gets server users from the local server or a target server."
  def users(client, target \\ nil)
  def users(client, nil), do: GenServer.call(client, {:send, "USERS", []})
  def users(client, target), do: GenServer.call(client, {:send, "USERS", [target]})

  @doc "Gets services that match an optional mask and type."
  def servlist(client, mask \\ nil, type \\ nil)
  def servlist(client, nil, nil), do: GenServer.call(client, {:send, "SERVLIST", []})
  def servlist(client, mask, nil), do: GenServer.call(client, {:send, "SERVLIST", [mask]})
  def servlist(client, mask, type), do: GenServer.call(client, {:send, "SERVLIST", [mask, type]})

  @doc "Enables or disables the user `+B` bot mode."
  def bot_mode(client, enabled \\ true), do: GenServer.call(client, {:bot_mode, enabled})

  @doc "Builds an account extban mask from the current `EXTBAN` token."
  def account_extban_mask(client, account, preferred_name \\ nil),
    do: GenServer.call(client, {:account_extban_mask, account, preferred_name})

  @doc "Returns `true` if the server denies the client-only tag."
  def client_tag_denied?(client, tag), do: GenServer.call(client, {:client_tag_denied?, tag})

  @doc "Sends an account `REGISTER` command."
  def register_account(client, account, email, password),
    do: GenServer.call(client, {:send, "REGISTER", [account, email, password]})

  @doc "Sends an account `VERIFY` command."
  def verify_account(client, account, code),
    do: GenServer.call(client, {:send, "VERIFY", [account, code]})

  @doc "Sets or clears the away state."
  def away(client, message \\ nil)
  def away(client, nil), do: GenServer.call(client, {:send, "AWAY", []})
  def away(client, message), do: GenServer.call(client, {:send, "AWAY", [message]})

  @doc "Sets the pre-registration away state without a reason."
  def preaway_unspecified(client), do: GenServer.call(client, {:send, "AWAY", ["*"]})

  @doc "Gets the read marker for a target."
  def markread_get(client, target), do: GenServer.call(client, {:send, "MARKREAD", [target]})

  @doc "Sets the read marker for a target."
  def markread_set(client, target, timestamp),
    do: GenServer.call(client, {:send, "MARKREAD", [target, "timestamp=#{timestamp}"]})

  @doc "Adds one or more targets to the monitor list."
  def monitor_add(client, targets),
    do: GenServer.call(client, {:send, "MONITOR", ["+", join_targets(targets)]})

  @doc "Removes one or more targets from the monitor list."
  def monitor_remove(client, targets),
    do: GenServer.call(client, {:send, "MONITOR", ["-", join_targets(targets)]})

  @doc "Clears the monitor list."
  def monitor_clear(client), do: GenServer.call(client, {:send, "MONITOR", ["C"]})

  @doc "Gets the monitor list."
  def monitor_list(client), do: GenServer.call(client, {:send, "MONITOR", ["L"]})

  @doc "Gets the current status of monitored targets."
  def monitor_status(client), do: GenServer.call(client, {:send, "MONITOR", ["S"]})

  @doc "Gets metadata keys for a target."
  def metadata_get(client, target, keys),
    do: GenServer.call(client, {:send, "METADATA", [target, "GET" | List.wrap(keys)]})

  @doc "Subscribes to metadata keys."
  def metadata_sub(client, keys),
    do: GenServer.call(client, {:send, "METADATA", ["*", "SUB" | List.wrap(keys)]})

  @doc "Unsubscribes from metadata keys."
  def metadata_unsub(client, keys),
    do: GenServer.call(client, {:send, "METADATA", ["*", "UNSUB" | List.wrap(keys)]})

  @doc "Sets a metadata key on a target."
  def metadata_set(client, target, key, value),
    do: GenServer.call(client, {:send, "METADATA", [target, "SET", key, value]})

  @doc "Clears a metadata key on a target."
  def metadata_clear_key(client, target, key),
    do: GenServer.call(client, {:send, "METADATA", [target, "SET", key]})

  @doc "Requests a metadata synchronization for a target."
  def metadata_sync(client, target),
    do: GenServer.call(client, {:send, "METADATA", [target, "SYNC"]})

  @doc "Gets the latest chat history for a target."
  def chathistory_latest(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:latest, target, selector, limit})}
      )

  @doc "Gets chat history before a message selector."
  def chathistory_before(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:before, target, selector, limit})}
      )

  @doc "Gets chat history after a message selector."
  def chathistory_after(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:after, target, selector, limit})}
      )

  @doc "Gets chat history around a message selector."
  def chathistory_around(client, target, selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY", ChatHistory.params({:around, target, selector, limit})}
      )

  @doc "Gets chat history between two message selectors."
  def chathistory_between(client, target, first_selector, second_selector, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY",
         ChatHistory.params({:between, target, first_selector, second_selector, limit})}
      )

  @doc "Gets history targets between two timestamps."
  def chathistory_targets(client, first_timestamp, second_timestamp, limit),
    do:
      GenServer.call(
        client,
        {:send, "CHATHISTORY",
         ChatHistory.params({:targets, first_timestamp, second_timestamp, limit})}
      )

  @doc "Requests the server `ISUPPORT` tokens."
  def isupport(client), do: GenServer.call(client, :send_isupport)

  @doc "Returns the upload URL from the current `FHOST` token."
  def filehost_upload_url(client), do: GenServer.call(client, :filehost_upload_url)

  @doc "Validates and sends a tagged IRC command."
  def raw_tagged(client, command, params, tags),
    do: GenServer.call(client, {:send, %Message{command: command, params: params, tags: tags}})

  @doc "Validates and sends an IRC command with a `label` tag."
  def labeled_raw(client, label, command, params \\ []),
    do: raw_tagged(client, command, params, %{"label" => label})

  @doc "Validates and sends an `Ircxd.Message`."
  def transmit(client, %Message{} = message), do: GenServer.call(client, {:send, message})

  @doc "Publishes all events in the manual server-time buffer."
  def flush_server_time(client), do: GenServer.call(client, :flush_server_time)

  @doc """
  Sends an IRCv3 client batch.

  Use `:required_cap` to require an active capability. `:capability` is an alias
  for `:required_cap`.
  """
  def client_batch(client, reference, type, params, messages, opts \\ []) do
    GenServer.call(client, {:send_client_batch, reference, type, params, messages, opts})
  end

  @doc """
  Sends a multiline `PRIVMSG` batch.

  Use `:ref` to set the batch reference. The client creates a reference if this
  option is absent.
  """
  def multiline_privmsg(client, target, body, opts \\ []) do
    GenServer.call(client, {:send_multiline, "PRIVMSG", target, body, opts})
  end

  @doc """
  Sends a multiline `NOTICE` batch.

  Use `:ref` to set the batch reference. The client creates a reference if this
  option is absent.
  """
  def multiline_notice(client, target, body, opts \\ []) do
    GenServer.call(client, {:send_multiline, "NOTICE", target, body, opts})
  end

  @impl true
  def init(opts) do
    transport_adapter_option = Keyword.get(opts, :transport_adapter)

    state = %{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, if(Keyword.get(opts, :tls, false), do: 6697, else: 6667)),
      tls: Keyword.get(opts, :tls, false),
      sni: Keyword.get(opts, :sni, Keyword.fetch!(opts, :host)),
      tls_options: Keyword.get(opts, :tls_options, []),
      allow_insecure_auth?: Keyword.get(opts, :allow_insecure_auth, false),
      password: Keyword.get(opts, :password),
      nick: Keyword.fetch!(opts, :nick),
      username: Keyword.get(opts, :username, Keyword.fetch!(opts, :nick)),
      realname: Keyword.get(opts, :realname, Keyword.fetch!(opts, :nick)),
      webirc: Keyword.get(opts, :webirc),
      reconnect: normalize_reconnect(Keyword.get(opts, :reconnect, false)),
      reconnect_attempts: 0,
      reconnect_timer: nil,
      connect_generation: 0,
      disconnect_intent: nil,
      caps: Keyword.get(opts, :caps, []),
      msgid_dedupe: Keyword.get(opts, :msgid_dedupe, false),
      seen_msgids: MapSet.new(),
      server_time_order: Keyword.get(opts, :server_time_order, false),
      resume_binding: normalize_resume_binding(Keyword.get(opts, :resume_binding)),
      server_time_buffer: [],
      server_time_flush_timer: nil,
      server_time_flush_generation: 0,
      event_mode: normalize_event_mode(Keyword.get(opts, :events, :legacy)),
      additional_error_numerics:
        normalize_additional_error_numerics(Keyword.get(opts, :additional_error_numerics, [])),
      available_caps: %{},
      active_caps: MapSet.new(),
      isupport: %{},
      current_nick: nil,
      nick_retry_fun: Keyword.get(opts, :nick_retry_fun, &default_nick_retry/2),
      sasl: Keyword.get(opts, :sasl),
      sasl_mechanisms: normalize_sasl(Keyword.get(opts, :sasl)),
      sasl_index: 0,
      sasl_scram: nil,
      sasl_failure_policy: Keyword.get(opts, :sasl_failure, :continue),
      sasl_in_progress?: false,
      socket: nil,
      transport: nil,
      transport_adapter: transport_adapter(transport_adapter_option),
      transport_adapter_arg: transport_adapter_arg(transport_adapter_option, opts),
      registered?: false,
      notify: Keyword.get(opts, :notify),
      adapter: nil,
      adapter_state: nil,
      active_batches: %{},
      cap_list_buffer: %{},
      multiline_batches: %{},
      labeled_response_batches: %{},
      labeled_requests: %{},
      isupport_batches: %{},
      metadata_batches: %{},
      net_batches: %{},
      multiline_ref: 0
    }

    case init_adapter(state, Keyword.get(opts, :adapter), Keyword.get(opts, :handler)) do
      {:ok, state} ->
        send(self(), {:connect, :initial, 0})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:adapter_init_failed, reason}}
    end
  end

  @impl true
  def handle_info(
        {:connect, origin, generation},
        %{socket: nil, connect_generation: generation} = state
      ) do
    state = %{state | reconnect_timer: nil}

    with {:ok, transport, socket, mode} <- connect(state) do
      state = %{state | transport: transport, socket: socket}

      case establish_connected(state, mode) do
        {:ok, state} ->
          {:noreply, state}

        {:error, reason} ->
          case release_transport(state, {:connect_rejected, reason}) do
            {:ok, state} ->
              handle_connect_failure(emit(state, {:connect_error, reason}), origin, reason)

            {:error, close_reason, state} ->
              reason = {:transport_close_failed, close_reason}
              {:stop, reason, emit(state, {:connect_error, reason})}
          end
      end
    else
      {:error, {:transport_close_failed, _close_reason} = reason} ->
        {:stop, reason, emit(state, {:connect_error, reason})}

      {:error, reason} ->
        state = emit(state, {:connect_error, reason})
        handle_connect_failure(state, origin, reason)
    end
  end

  def handle_info({:connect, _origin, _generation}, state), do: {:noreply, state}

  def handle_info(
        {:ircxd_transport, handle, {:data, receipt, line}},
        %{socket: handle} = state
      )
      when is_binary(line) do
    handle_transport_line(line, receipt, state)
  end

  def handle_info(
        {:ircxd_transport, handle, {:closed, reason}},
        %{socket: handle} = state
      ),
      do: handle_disconnect(state, reason)

  def handle_info({:ircxd_transport, _handle, _event}, state), do: {:noreply, state}

  def handle_info(
        {:flush_server_time, generation},
        %{server_time_flush_generation: generation} = state
      ) do
    {:noreply, flush_server_time_buffer(%{state | server_time_flush_timer: nil})}
  end

  def handle_info({:flush_server_time, _generation}, state), do: {:noreply, state}

  def handle_info(message, %{socket: handle, transport_adapter: adapter} = state)
      when not is_nil(handle) do
    case adapter.handle_info(message, handle) do
      {:data, receipt, line} when is_binary(line) -> handle_transport_line(line, receipt, state)
      {:closed, reason} -> handle_disconnect(state, reason)
      :unknown -> {:noreply, state}
      _invalid -> handle_disconnect(state, :invalid_transport_event)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:send, %Message{} = message}, _from, state) do
    case send_message(state, message) do
      :ok ->
        state = state |> maybe_track_labeled_request(message) |> maybe_mark_quit_intent(message)
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:send, command, params}, _from, state) do
    case send_message(state, command, params) do
      :ok -> {:reply, :ok, maybe_mark_quit_intent(state, command)}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:reconnect, _from, %{socket: nil} = state) do
    state =
      state
      |> cancel_reconnect_timer()
      |> Map.put(:disconnect_intent, nil)
      |> schedule_reconnect(1, 0)

    {:reply, :ok, state}
  end

  def handle_call(:reconnect, _from, state), do: {:reply, {:error, :already_connected}, state}

  def handle_call(:connection_info, _from, state), do: {:reply, client_info(state), state}

  def handle_call({:self_nick?, nick}, _from, state) do
    {:reply, identifier_self?(state, nick), state}
  end

  def handle_call({:same_identifier?, left, right}, _from, state) do
    result = is_binary(left) and is_binary(right) and ISupport.equal?(state.isupport, left, right)
    {:reply, result, state}
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

  def handle_call({:disable_caps, caps}, _from, state) do
    caps = caps |> Enum.map(&to_string/1) |> Enum.uniq()

    result =
      with :ok <- ensure_active_caps(state, caps) do
        send_message(state, "CAP", ["REQ", caps |> Enum.map(&("-" <> &1)) |> Enum.join(" ")])
      end

    case result do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:cap_list, _from, state) do
    case send_message(state, "CAP", ["LIST"]) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:bot_mode, enabled}, _from, state) do
    case ISupport.bot_mode(state.isupport) do
      mode when is_binary(mode) ->
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
    state = state |> cancel_server_time_flush_timer() |> flush_server_time_buffer()
    {:reply, :ok, state}
  end

  def handle_call({:send_client_batch, reference, type, params, messages, opts}, _from, state) do
    result =
      with :ok <- require_client_batch_cap(state, opts),
           {:ok, messages} <- normalize_client_batch_messages(messages),
           {:ok, reference, type, params} <-
             normalize_client_batch_header(state, reference, type, params),
           {:ok, messages} <- prepare_client_batch_messages(state, messages, reference) do
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

  @impl true
  def terminate(reason, state) do
    _result = release_transport(state, {:client_terminated, reason})
    :ok
  end

  @doc false
  def __tls_connect_options__(state) do
    SocketTransport.tls_connect_options(state)
  end

  defp connect(%{transport_adapter: adapter} = state) do
    config = %{
      host: state.host,
      port: state.port,
      tls?: state.tls,
      sni: state.sni
    }

    case adapter.connect(self(), config, state.transport_adapter_arg) do
      {:ok, handle, :fresh} when not is_nil(handle) ->
        {:ok, transport_name(adapter, handle), handle, :fresh}

      {:ok, handle, {:resumed, resume, metadata}} when not is_nil(handle) and is_map(metadata) ->
        {:ok, transport_name(adapter, handle), handle, {:resumed, resume, metadata}}

      {:ok, handle, _invalid_mode} when not is_nil(handle) ->
        reject_connected_handle(adapter, handle, :invalid_transport_result)

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_transport_result}
    end
  end

  defp maybe_send_webirc(%{webirc: nil}), do: :ok

  defp maybe_send_webirc(%{tls: false, allow_insecure_auth?: false}), do: :ok

  defp maybe_send_webirc(%{webirc: webirc} = state) do
    send_message(state, "WEBIRC", WebIRC.params(webirc))
  end

  defp maybe_send_pass(%{password: nil}), do: :ok
  defp maybe_send_pass(%{password: ""}), do: :ok
  defp maybe_send_pass(%{tls: false, allow_insecure_auth?: false}), do: :ok
  defp maybe_send_pass(%{password: password} = state), do: send_message(state, "PASS", [password])

  defp handle_disconnect(state, reason) do
    intentional? = state.disconnect_intent == :quit
    reconnecting? = not intentional? and reconnect?(state)
    attempt = state.reconnect_attempts + 1
    delay = if reconnecting?, do: state.reconnect.delay

    state = fail_labeled_requests(state, if(intentional?, do: :quit, else: reason))

    case release_transport(state, reason) do
      {:ok, state} ->
        state = state |> reset_connection_state() |> emit(:disconnected)

        state =
          emit(
            state,
            {:disconnect,
             %{
               reason: if(intentional?, do: :quit, else: reason),
               intentional?: intentional?,
               reconnecting?: reconnecting?
             }}
          )

        cond do
          intentional? ->
            {:noreply, state}

          reconnecting? ->
            state =
              state
              |> schedule_reconnect(attempt, delay)
              |> emit({:reconnecting, %{attempt: attempt, delay: delay}})

            {:noreply, state}

          true ->
            {:stop, :normal, state}
        end

      {:error, close_reason, state} ->
        close_failure = {:transport_close_failed, close_reason}

        state =
          state
          |> emit(:disconnected)
          |> emit(
            {:disconnect, %{reason: close_failure, intentional?: false, reconnecting?: false}}
          )

        {:stop, close_failure, state}
    end
  end

  defp reset_connection_state(state) do
    state = cancel_server_time_flush_timer(state)

    Map.merge(state, %{
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
      cap_list_buffer: %{},
      seen_msgids: MapSet.new(),
      server_time_buffer: [],
      server_time_flush_timer: nil,
      disconnect_intent: nil,
      current_nick: nil
    })
  end

  defp fail_labeled_requests(state, reason) do
    Enum.reduce(state.labeled_requests, state, fn {_label, request}, state ->
      emit(state, {:labeled_request, Map.merge(request, %{status: :failed, reason: reason})})
    end)
  end

  defp maybe_mark_quit_intent(state, %Message{command: command}),
    do: maybe_mark_quit_intent(state, command)

  defp maybe_mark_quit_intent(state, command) when is_binary(command) do
    if String.upcase(command) == "QUIT", do: %{state | disconnect_intent: :quit}, else: state
  end

  defp maybe_mark_quit_intent(state, _command), do: state

  defp handle_connect_failure(state, :initial, reason), do: {:stop, reason, state}

  defp handle_connect_failure(state, {:retry, _attempt}, reason) do
    if reconnect?(state) do
      attempt = state.reconnect_attempts + 1
      delay = state.reconnect.delay

      state =
        state
        |> schedule_reconnect(attempt, delay)
        |> emit({:reconnecting, %{attempt: attempt, delay: delay}})

      {:noreply, state}
    else
      exhausted = %{
        attempts: state.reconnect_attempts,
        max_attempts:
          if(state.reconnect, do: state.reconnect.max_attempts, else: state.reconnect_attempts),
        reason: reason
      }

      {:stop, :normal, emit(state, {:reconnect_exhausted, exhausted})}
    end
  end

  defp schedule_reconnect(state, attempt, delay) do
    generation = state.connect_generation + 1

    timer =
      Process.send_after(self(), {:connect, {:retry, attempt}, generation}, delay)

    %{
      state
      | connect_generation: generation,
        reconnect_attempts: attempt,
        reconnect_timer: timer
    }
  end

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  defp cancel_reconnect_timer(state), do: state

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
          request_caps_or_end(state, message)
        else
          {:noreply, state}
        end

      {:ok, %Message{command: "CAP", params: [_nick, "LIST" | params]} = message} ->
        state = collect_cap_list(state, List.last(params) || "")
        state = emit(state, {:message, message})

        if cap_list_complete?(message) do
          state = emit_event(state, {:cap_list, state.cap_list_buffer}, message)
          {:noreply, %{state | cap_list_buffer: %{}}}
        else
          {:noreply, state}
        end

      {:ok, %Message{command: "CAP", params: [_nick, "ACK", caps]} = message} ->
        acked_caps = String.split(caps, " ", trim: true)
        {disabled_caps, enabled_caps} = split_acked_caps(acked_caps)

        active_caps =
          state.active_caps
          |> MapSet.union(MapSet.new(enabled_caps))
          |> MapSet.difference(MapSet.new(disabled_caps))

        state = %{state | active_caps: active_caps}
        state = emit_event(state, {:cap_ack, acked_caps}, message)
        state = emit(state, {:message, message})

        if should_start_sasl?(state, acked_caps) do
          state = select_first_sasl_mechanism(state)
          send_sasl_start(state)
          {:noreply, %{state | sasl_in_progress?: true}}
        else
          maybe_end_cap_negotiation(state)
          {:noreply, state}
        end

      {:ok, %Message{command: "CAP", params: [_nick, "NAK", caps]} = message} ->
        nacked_caps = String.split(caps, " ", trim: true)
        state = emit_event(state, {:cap_nak, nacked_caps}, message)
        state = emit(state, {:message, message})
        maybe_end_cap_negotiation(state)
        {:noreply, state}

      {:ok, %Message{command: "CAP", params: [_nick, "NEW", caps]} = message} ->
        new_caps = parse_caps(caps)
        state = %{state | available_caps: Map.merge(state.available_caps, new_caps)}
        state = emit_event(state, {:cap_new, new_caps}, message)
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

        state = maybe_emit_cap_del(state, deleted_caps, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "AUTHENTICATE", params: [payload]} = message} ->
        state = handle_sasl_authenticate(state, payload, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "903"} = message} ->
        if sasl_scram_verified_or_unused?(state) do
          state = emit_event(state, :sasl_success, message)
          state = emit(state, {:message, message})
          send_message(state, "CAP", ["END"])
          {:noreply, %{state | sasl_in_progress?: false, sasl_scram: nil}}
        else
          state =
            emit_event(
              state,
              {:sasl_scram_error, %{reason: :missing_verified_server_final}},
              message
            )

          state = emit(state, {:message, message})
          send_message(state, "QUIT", ["SASL SCRAM verification failed"])
          {:stop, :sasl_failure, state}
        end

      {:ok, %Message{command: "908", params: [_nick, mechanisms | _rest]} = message} ->
        state =
          emit_event(
            state,
            {:sasl_mechanisms, %{mechanisms: parse_sasl_mechanisms(mechanisms)}},
            message
          )

        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: command} = message}
      when command in ["902", "904", "905", "906", "907"] ->
        handle_sasl_failure(state, command, message)

      {:ok, %Message{command: "001", params: [nick | _rest]} = message} ->
        state = %{state | registered?: true, current_nick: nick, reconnect_attempts: 0}
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
        attempted = Enum.at(params, 1) || state.current_nick || state.nick
        {state, next_nick} = maybe_retry_nick(state, attempted)

        state =
          emit_event(
            state,
            {:nick_in_use,
             %{attempted: attempted, next: next_nick, reason: List.last(params), message: message}},
            message
          )

        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "353", params: [_nick, symbol, channel, names]} = message} ->
        state =
          emit_event(
            state,
            {:names, %{symbol: symbol, channel: channel, names: Names.parse_names(names)}},
            message
          )

        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "366", params: [_nick, channel | _rest]} = message} ->
        state = emit_event(state, {:names_end, %{channel: channel, message: message}}, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "352"} = message} ->
        state =
          emit_event(
            state,
            {:who_reply, Who.parse_reply(message.params, ISupport.bot_mode(state.isupport))},
            message
          )

        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "354"} = message} ->
        state = emit_event(state, {:whox_reply, Who.parse_whox(message.params)}, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %Message{command: "315", params: [_me, mask | _rest]} = message} ->
        state = emit_event(state, {:who_end, %{mask: mask}}, message)
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
        event = attach_identity_metadata(state, event_for(message, state))
        state = update_current_nick(state, message)
        state = emit_event(state, event, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:error, reason} ->
        state = emit(state, {:parse_error, reason, line})
        {:noreply, state}
    end
  end

  defp maybe_retry_nick(%{registered?: true} = state, _attempted), do: {state, nil}

  defp maybe_retry_nick(state, attempted) do
    next_nick = state.nick_retry_fun.(attempted, state)
    send_message(state, "NICK", [next_nick])
    {state, next_nick}
  end

  defp handle_transport_line(line, receipt, state) do
    case handle_line(line, state) do
      {:noreply, next_state} ->
        checkpoint =
          if state.transport_adapter.checkpoint?(state.socket),
            do: Resume.checkpoint(next_state),
            else: nil

        with :ok <- state.transport_adapter.accepted(state.socket, receipt, checkpoint),
             :ok <- activate_socket(next_state) do
          {:noreply, next_state}
        else
          {:error, reason} -> handle_disconnect(next_state, {:transport_error, reason})
        end

      other ->
        other
    end
  end

  defp activate_socket(%{transport_adapter: adapter, socket: socket}),
    do: adapter.activate(socket)

  defp update_current_nick(
         state,
         %Message{command: "NICK", source: source, params: [new_nick]}
       ) do
    case Source.parse(source) do
      %Source{nick: nick} when is_binary(nick) ->
        if identifier_self?(state, nick), do: %{state | current_nick: new_nick}, else: state

      _ ->
        state
    end
  end

  defp update_current_nick(state, _message), do: state

  defp collect_caps(state, caps) do
    %{state | available_caps: Map.merge(state.available_caps, parse_caps(caps))}
  end

  defp collect_cap_list(state, caps) do
    %{state | cap_list_buffer: Map.merge(state.cap_list_buffer, parse_caps(caps))}
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

  defp cap_list_complete?(%Message{params: [_nick, subcommand, "*" | _]})
       when subcommand in ["LS", "LIST"],
       do: false

  defp cap_list_complete?(_), do: true

  defp split_acked_caps(acked_caps) do
    Enum.reduce(acked_caps, {[], []}, fn
      "-" <> cap, {disabled, enabled} -> {[cap | disabled], enabled}
      cap, {disabled, enabled} -> {disabled, [cap | enabled]}
    end)
  end

  defp request_caps_or_end(state, message) do
    requested =
      state.caps
      |> maybe_include_sasl(state)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "sts"))
      |> Enum.filter(&Map.has_key?(state.available_caps, &1))

    if requested == [] do
      send_message(state, "CAP", ["END"])
    else
      send_message(state, "CAP", ["REQ", Enum.join(requested, " ")])
    end

    state = emit_event(state, {:cap_ls, state.available_caps}, message)
    {:noreply, state}
  end

  defp maybe_end_cap_negotiation(%{registered?: true}), do: :ok
  defp maybe_end_cap_negotiation(state), do: send_message(state, "CAP", ["END"])

  defp maybe_emit_sts_policy(state, {name, %{"sts" => value} = source_payload}, message)
       when name in [:cap_ls, :cap_new] do
    case STS.parse(value, state.tls) do
      {:ok, policy} ->
        emit_related_event(
          state,
          {:sts_policy,
           policy
           |> Map.put(:host, state.host)
           |> Map.put(:tls?, state.tls)},
          source_payload,
          message
        )

      {:error, reason} ->
        emit_related_event(
          state,
          {:sts_policy_error, %{host: state.host, value: value, reason: reason}},
          source_payload,
          message
        )
    end
  end

  defp maybe_emit_sts_policy(state, _event, _message), do: state

  defp maybe_emit_cap_del(state, [], _message), do: state

  defp maybe_emit_cap_del(state, deleted_caps, message),
    do: emit_event(state, {:cap_del, deleted_caps}, message)

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

  defp event_for(%Message{command: "PONG", source: source, params: [target, token]} = message) do
    parsed_source = Source.parse(source)

    {:pong,
     %{
       source: parsed_source,
       raw_source: source,
       server: parsed_source && (parsed_source.server || parsed_source.nick),
       target: target,
       token: token,
       message: message
     }}
  end

  defp event_for(%Message{command: "PONG", source: source, params: [token]} = message) do
    parsed_source = Source.parse(source)

    {:pong,
     %{
       source: parsed_source,
       raw_source: source,
       server: parsed_source && (parsed_source.server || parsed_source.nick),
       target: nil,
       token: token,
       message: message
     }}
  end

  defp event_for(%Message{command: "WALLOPS", source: source, params: [body]} = message) do
    parsed_source = Source.parse(source)

    {:wallops,
     %{
       source: parsed_source,
       raw_source: source,
       nick: parsed_source && (parsed_source.nick || parsed_source.server),
       body: body,
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
    do:
      {:userhost,
       %{
         replies: String.split(replies, " ", trim: true),
         entries: UserHost.parse_replies(replies),
         message: message
       }}

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

  defp event_for(%Message{command: "900", params: [_me, userhost, account, text]} = message),
    do: {:logged_in, %{userhost: userhost, account: account, text: text, message: message}}

  defp event_for(%Message{command: "901", params: [_me, userhost, text]} = message),
    do: {:logged_out, %{userhost: userhost, text: text, message: message}}

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
    do: {:users_empty, %{text: text, message: message}}

  defp event_for(%Message{command: "446", params: [_me, text]} = message),
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
    irc_error_event(command, params, message)
  end

  defp event_for(%Message{command: command, params: params} = message)
       when command in ["FAIL", "WARN", "NOTE"] do
    case StandardReply.parse(command, params) do
      {:ok, reply} -> {:standard_reply, Map.put(reply, :message, message)}
      {:error, reason} -> {:standard_reply_error, %{reason: reason, message: message}}
    end
  end

  defp event_for(message), do: {:raw, message}

  defp event_for(%Message{} = message, state) do
    case event_for(message) do
      {:raw, %Message{command: command, params: [_me | params]}} = raw ->
        if MapSet.member?(state.additional_error_numerics, command) do
          irc_error_event(command, params, message)
        else
          raw
        end

      event ->
        event
    end
  end

  defp irc_error_event(command, params, message) do
    {:irc_error,
     %{
       code: command,
       target: error_target(params),
       reason: List.last(params),
       params: params,
       message: message
     }}
  end

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
        batch = %{type: type, params: batch_params, message: message, parent: Tags.batch(message)}
        state = %{state | active_batches: Map.put(state.active_batches, ref, batch)}
        state = maybe_start_multiline(state, ref, batch)
        state = maybe_start_labeled_response_batch(state, ref, batch)
        state = maybe_start_isupport_batch(state, ref, batch)
        state = maybe_start_metadata_batch(state, ref, batch)
        state = maybe_start_net_batch(state, ref, batch)
        state = emit_event(state, {:batch_start, Map.put(batch, :ref, ref)}, message)
        state = emit(state, {:message, message})
        {:noreply, state}

      {:ok, %{direction: :end, ref: ref}} ->
        {batch, active_batches} = Map.pop(state.active_batches, ref)

        if is_nil(batch) do
          state =
            emit_event(
              state,
              {:batch_error, %{reason: :unknown_batch, ref: ref, message: message}},
              message
            )

          state = emit(state, {:message, message})
          {:noreply, state}
        else
          label = labeled_batch_value(state, ref, :label)
          state = %{state | active_batches: active_batches}
          state = maybe_emit_multiline(state, ref, batch)
          state = maybe_emit_labeled_response_batch(state, ref, batch)
          state = maybe_emit_isupport_batch(state, ref, batch)
          state = maybe_emit_metadata_batch(state, ref, batch)
          state = maybe_emit_net_batch(state, ref, batch)

          state =
            emit_event(state, {:batch_end, %{ref: ref, batch: batch, label: label}}, message)

          state = emit(state, {:message, message})
          {:noreply, state}
        end

      {:error, reason} ->
        state = emit_event(state, {:batch_error, %{reason: reason, message: message}}, message)
        state = emit(state, {:message, message})
        {:noreply, state}
    end
  end

  defp emit_event(state, event, message) do
    event = attach_message_metadata(state, event, message)
    {state, event} = maybe_mark_duplicate_msgid(state, event)
    {state, batch_context} = collect_batched_event(state, event, message)
    server_time = server_time_for_event(event, message)

    if buffer_server_time?(state, server_time) do
      {state, labeled_lifecycle_processed?} =
        process_buffered_labeled_lifecycle(state, event, message)

      entry = %{
        time: server_time,
        event: event,
        message: message,
        batch_context: batch_context,
        labeled_lifecycle_processed?: labeled_lifecycle_processed?,
        index: length(state.server_time_buffer)
      }

      state
      |> Map.update!(:server_time_buffer, &[entry | &1])
      |> maybe_schedule_server_time_flush()
    else
      emit_event_now(state, event, message, batch_context, false)
    end
  end

  defp attach_message_metadata(state, {name, payload}, message) when is_map(payload) do
    metadata = %{
      raw_message: message,
      label: message_label(state, message),
      batch: Tags.batch(message),
      server_time: tag_value(message, &Tags.server_time/1)
    }

    payload = Map.merge(metadata, payload)

    payload =
      case {metadata.server_time, Map.get(payload, :server_time)} do
        {%DateTime{} = server_time, value} when not is_struct(value, DateTime) ->
          Map.put(payload, :server_time, server_time)

        _other ->
          payload
      end

    state
    |> attach_identity_metadata({name, payload})
  end

  defp attach_message_metadata(_state, event, _message), do: event

  @source_identity_events ~w(
    account away channel_rename chghost invite join kick mode nick notice part pong
    privmsg quit redact setname tagmsg topic wallops
  )a
  @target_identity_events ~w(invite kick mode notice privmsg redact tagmsg)a

  defp attach_identity_metadata(state, {name, payload})
       when is_map(payload) and name in @source_identity_events do
    source_key = source_identity_key(name)
    payload = Map.put_new(payload, :source_self?, identifier_self?(state, payload[source_key]))
    payload = maybe_attach_target_identity(state, name, payload)
    {name, payload}
  end

  defp attach_identity_metadata(_state, event), do: event

  defp source_identity_key(:nick), do: :old_nick
  defp source_identity_key(:pong), do: :server
  defp source_identity_key(_name), do: :nick

  defp maybe_attach_target_identity(state, name, payload)
       when name in @target_identity_events do
    target_key = if name == :kick, do: :target_nick, else: :target
    Map.put_new(payload, :target_self?, identifier_self?(state, payload[target_key]))
  end

  defp maybe_attach_target_identity(_state, _name, payload), do: payload

  defp identifier_self?(%{current_nick: current_nick, isupport: isupport}, nick)
       when is_binary(current_nick) and is_binary(nick),
       do: ISupport.equal?(isupport, current_nick, nick)

  defp identifier_self?(_state, _nick), do: false

  defp message_label(state, message) do
    case Tags.label(message) do
      label when is_binary(label) ->
        label

      _ ->
        labeled_batch_value(state, Tags.batch(message), :label)
    end
  end

  defp labeled_batch_value(state, ref, key) when is_binary(ref) do
    case labeled_response_ref(state, ref) do
      nil -> nil
      labeled_ref -> get_in(state.labeled_response_batches, [labeled_ref, key])
    end
  end

  defp labeled_batch_value(_state, _ref, _key), do: nil

  defp labeled_response_ref(state, ref), do: labeled_response_ref(state, ref, MapSet.new())

  defp labeled_response_ref(_state, nil, _seen), do: nil

  defp labeled_response_ref(state, ref, seen) do
    cond do
      MapSet.member?(seen, ref) ->
        nil

      Map.has_key?(state.labeled_response_batches, ref) ->
        ref

      true ->
        parent = get_in(state.active_batches, [ref, :parent])
        labeled_response_ref(state, parent, MapSet.put(seen, ref))
    end
  end

  defp flush_server_time_buffer(state) do
    state.server_time_buffer
    |> Enum.sort_by(fn %{time: time, index: index} ->
      {DateTime.to_unix(time, :microsecond), index}
    end)
    |> Enum.reduce(
      %{state | server_time_buffer: []},
      fn %{
           event: event,
           message: message,
           batch_context: batch_context,
           labeled_lifecycle_processed?: labeled_lifecycle_processed?
         },
         state ->
        emit_event_now(
          state,
          event,
          message,
          batch_context,
          labeled_lifecycle_processed?
        )
      end
    )
  end

  defp emit_event_now(
         state,
         event,
         message,
         batch_context,
         labeled_lifecycle_processed?
       ) do
    state =
      state
      |> maybe_emit_duplicate_msgid(event)
      |> emit(event, message)
      |> maybe_emit_sts_policy(event, message)
      |> maybe_emit_typing(event)
      |> maybe_emit_reaction(event)
      |> maybe_emit_labeled_response(event, message, labeled_lifecycle_processed?)
      |> maybe_emit_batched(event, message, batch_context)

    state
  end

  defp buffer_server_time?(%{server_time_order: :manual}, %DateTime{}), do: true

  defp buffer_server_time?(%{server_time_order: opts}, %DateTime{}) when is_list(opts),
    do: Keyword.has_key?(opts, :flush_after)

  defp buffer_server_time?(_state, _server_time), do: false

  defp maybe_schedule_server_time_flush(
         %{server_time_order: opts, server_time_flush_timer: nil} = state
       )
       when is_list(opts) do
    delay = Keyword.fetch!(opts, :flush_after)
    generation = state.server_time_flush_generation + 1

    timer =
      Process.send_after(self(), {:flush_server_time, generation}, delay)

    %{state | server_time_flush_timer: timer, server_time_flush_generation: generation}
  end

  defp maybe_schedule_server_time_flush(state), do: state

  defp cancel_server_time_flush_timer(%{server_time_flush_timer: timer} = state)
       when is_reference(timer) do
    Process.cancel_timer(timer)

    %{
      state
      | server_time_flush_timer: nil,
        server_time_flush_generation: state.server_time_flush_generation + 1
    }
  end

  defp cancel_server_time_flush_timer(state), do: state

  defp server_time_from_event({_name, %{server_time: %DateTime{} = server_time}}), do: server_time
  defp server_time_from_event(_event), do: nil

  defp server_time_for_event(event, message),
    do: server_time_from_event(event) || tag_value(message, &Tags.server_time/1)

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

  @related_event_metadata ~w(
    raw_message label batch server_time msgid duplicate_msgid?
  )a

  defp emit_related_event(state, {name, payload}, source_payload, message)
       when is_map(payload) and is_map(source_payload) do
    metadata = Map.take(source_payload, @related_event_metadata)
    emit(state, {name, Map.merge(metadata, payload)}, message)
  end

  defp maybe_emit_typing(
         state,
         {:tagmsg,
          %{
            source: source,
            raw_source: raw_source,
            nick: nick,
            target: target,
            source_self?: source_self?,
            target_self?: target_self?,
            tags: %{"+typing" => status},
            message: message
          } = source_payload}
       ) do
    emit_related_event(
      state,
      {:typing,
       %{
         source: source,
         raw_source: raw_source,
         nick: nick,
         target: target,
         source_self?: source_self?,
         target_self?: target_self?,
         status: parse_typing_status(status),
         raw_status: status,
         message: message
       }},
      source_payload,
      message
    )
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
            source_self?: source_self?,
            target_self?: target_self?,
            tags: tags,
            message: message
          } = source_payload}
       ) do
    case reaction_from_tags(tags) do
      nil ->
        state

      %{action: action, reaction: reaction, reply_to_msgid: reply_to_msgid} ->
        emit_related_event(
          state,
          {:reaction,
           %{
             source: source,
             raw_source: raw_source,
             nick: nick,
             target: target,
             source_self?: source_self?,
             target_self?: target_self?,
             action: action,
             reaction: reaction,
             reply_to_msgid: reply_to_msgid,
             message: message
           }},
          source_payload,
          message
        )
    end
  end

  defp maybe_emit_reaction(state, _event), do: state

  defp process_buffered_labeled_lifecycle(state, {:batch_start, _payload}, _message),
    do: {state, false}

  defp process_buffered_labeled_lifecycle(state, event, message) do
    case Tags.label(message) do
      nil ->
        {state, false}

      label ->
        state =
          state
          |> maybe_ack_labeled_request(event)
          |> maybe_complete_labeled_request(event, label)

        {state, true}
    end
  end

  defp maybe_emit_labeled_response(
         state,
         {:batch_start, _payload},
         _message,
         _lifecycle_processed?
       ),
       do: state

  defp maybe_emit_labeled_response(state, event, message, lifecycle_processed?) do
    state = if lifecycle_processed?, do: state, else: maybe_ack_labeled_request(state, event)

    case Tags.label(message) do
      nil ->
        state

      label ->
        state = emit(state, {:labeled_response, %{label: label, event: event, message: message}})

        if lifecycle_processed? do
          state
        else
          maybe_complete_labeled_request(state, event, label)
        end
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

  defp maybe_complete_labeled_request(state, {:ack, _payload}, label),
    do: finish_labeled_request(state, label, :ack, :ack)

  defp maybe_complete_labeled_request(state, event, label),
    do: finish_labeled_request(state, label, :single, event)

  defp finish_labeled_request(state, label, response_type, response) do
    case Map.fetch(state.labeled_requests, label) do
      {:ok, request} ->
        request =
          request
          |> Map.put(:response_type, response_type)
          |> put_labeled_request_outcome(response)

        state
        |> Map.update!(:labeled_requests, &Map.delete(&1, label))
        |> emit({:labeled_request, request})

      :error ->
        state
    end
  end

  defp put_labeled_request_outcome(request, response) do
    case labeled_failure(response) do
      nil -> Map.put(request, :status, :completed)
      failure -> Map.merge(request, %{status: :failed, reason: failure})
    end
  end

  @labeled_failure_names ~w(
    batch_error chathistory_error error irc_error metadata_error metadata_reply_error
    monitor_error motd_missing nick_in_use read_marker_error sasl_failure sasl_scram_error
    standard_reply_error starttls_failed try_again users_disabled
  )a

  defp labeled_failure({:standard_reply, %{type: :fail}} = event), do: event
  defp labeled_failure({:monitor, %{type: :list_full}} = event), do: event

  defp labeled_failure({:batch, %{events: events}}) do
    Enum.find_value(events, &labeled_failure/1)
  end

  defp labeled_failure({name, _payload} = event) when name in @labeled_failure_names, do: event
  defp labeled_failure(_response), do: nil

  defp collect_batched_event(state, event, message) do
    case Tags.batch(message) do
      nil ->
        {state, nil}

      ref ->
        batch_context = %{ref: ref, batch: Map.get(state.active_batches, ref)}
        state = maybe_collect_multiline(state, ref, event, message)
        state = maybe_collect_labeled_response_batch(state, ref, event)
        state = maybe_collect_isupport_batch(state, ref, event)
        state = maybe_collect_metadata_batch(state, ref, event)
        state = maybe_collect_net_batch(state, ref, event)
        {state, batch_context}
    end
  end

  defp maybe_emit_batched(state, _event, _message, nil), do: state

  defp maybe_emit_batched(state, event, message, %{ref: ref, batch: batch}) do
    emit(
      state,
      {:batched, %{ref: ref, batch: batch, event: event, message: message}}
    )
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
        emit_related_event(
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
             source_self?: first_payload.source_self?,
             target_self?: first_payload.target_self?,
             lines: lines
           }},
          first_payload,
          first_payload.raw_message
        )

      _ ->
        state
    end
  end

  defp maybe_emit_multiline(state, ref, _batch) do
    %{state | multiline_batches: Map.delete(state.multiline_batches, ref)}
  end

  defp maybe_start_labeled_response_batch(state, ref, %{message: message} = batch) do
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
    labeled_ref = labeled_response_ref(state, ref)

    case Map.fetch(state.labeled_response_batches, labeled_ref) do
      {:ok, batch} ->
        batch = %{batch | events: batch.events ++ [event]}

        %{
          state
          | labeled_response_batches: Map.put(state.labeled_response_batches, labeled_ref, batch)
        }

      :error ->
        state
    end
  end

  defp maybe_emit_labeled_response_batch(state, ref, _batch) do
    {batch, labeled_response_batches} = Map.pop(state.labeled_response_batches, ref)
    state = %{state | labeled_response_batches: labeled_response_batches}

    case batch do
      %{label: label, type: type, events: events} ->
        response = {:batch, %{ref: ref, type: type, events: events}}

        state
        |> emit({:labeled_response, %{label: label, event: response}})
        |> finish_labeled_request(label, :batch, response)

      _ ->
        state
    end
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
    with {:ok, params} <- normalize_outbound_params(params) do
      send_message(state, %Message{command: command, params: params})
    end
  end

  defp send_message(%{transport: nil}, %Message{}), do: {:error, :not_connected}

  defp send_message(state, %Message{} = message) do
    message = ClientCommand.normalize(message)

    with :ok <- validate_outbound_message(state, message) do
      line = Message.serialize(message)

      state.transport_adapter.send_data(state.socket, line)
    end
  end

  defp validate_outbound_message(state, message) do
    with :ok <- ClientCommand.validate(message, tags: :allow),
         :ok <- validate_outbound_command(state, message),
         :ok <- validate_utf8_only(state, message) do
      validate_outbound_tags(state, message)
    end
  end

  defp normalize_outbound_params(params) when is_list(params) do
    Enum.reduce_while(params, {:ok, []}, fn
      value, {:ok, params} when is_binary(value) ->
        {:cont, {:ok, [value | params]}}

      value, {:ok, params} when is_integer(value) ->
        {:cont, {:ok, [Integer.to_string(value) | params]}}

      _value, _acc ->
        {:halt, {:error, :invalid_param}}
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      error -> error
    end
  end

  defp normalize_outbound_params(_params), do: {:error, :invalid_param}

  defp validate_outbound_command(state, %Message{command: "REDACT"}) do
    with :ok <- require_active_cap(state, "draft/message-redaction") do
      require_active_cap(state, "message-tags")
    end
  end

  defp validate_outbound_command(
         %{tls: false, allow_insecure_auth?: false},
         %Message{command: command}
       )
       when command in ["AUTHENTICATE", "OPER", "PASS", "REGISTER", "VERIFY", "WEBIRC"],
       do: {:error, :insecure_authentication}

  defp validate_outbound_command(state, %Message{command: "MARKREAD"}),
    do: require_active_cap(state, "draft/read-marker")

  defp validate_outbound_command(state, %Message{command: "RENAME"}),
    do: require_active_cap(state, "draft/channel-rename")

  defp validate_outbound_command(state, %Message{command: "SETNAME"}),
    do: require_active_cap(state, "setname")

  defp validate_outbound_command(state, %Message{command: "TAGMSG"}),
    do: require_active_cap(state, "message-tags")

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

  defp validate_outbound_tags(state, %Message{tags: tags}) when is_map(tags) do
    with :ok <- maybe_require_labeled_response(state, tags) do
      maybe_require_message_tags(state, tags)
    end
  end

  defp validate_outbound_tags(_state, _message), do: :ok

  defp maybe_require_labeled_response(state, tags) do
    if Map.has_key?(tags, "label") do
      with :ok <- require_active_cap(state, "labeled-response") do
        require_active_cap(state, "batch")
      end
    else
      :ok
    end
  end

  defp maybe_require_message_tags(state, tags) do
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

  defp ensure_active_caps(_state, []), do: {:error, :missing_capabilities}

  defp ensure_active_caps(state, caps) do
    case Enum.reject(caps, &MapSet.member?(state.active_caps, &1)) do
      [] -> :ok
      missing -> {:error, {:capabilities_not_enabled, missing}}
    end
  end

  defp require_client_batch_cap(state, opts) do
    case Keyword.get(opts, :required_cap) || Keyword.get(opts, :capability) do
      cap when is_binary(cap) -> require_active_cap(state, cap)
      nil -> {:error, :missing_client_batch_capability}
    end
  end

  defp maybe_include_sasl(caps, %{sasl: nil}), do: caps

  defp maybe_include_sasl(caps, %{tls: false, allow_insecure_auth?: false}), do: caps

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

  defp normalize_resume_binding(nil), do: nil
  defp normalize_resume_binding(binding) when is_binary(binding), do: binding

  defp normalize_resume_binding(_binding) do
    raise ArgumentError, ":resume_binding must be a binary or nil"
  end

  defp normalize_event_mode(mode) when mode in [:legacy, :envelope, :both], do: mode

  defp normalize_event_mode(mode) do
    raise ArgumentError,
          "expected :events to be :legacy, :envelope, or :both, got: #{inspect(mode)}"
  end

  defp normalize_additional_error_numerics(numerics) when is_list(numerics) do
    if Enum.all?(numerics, &(is_binary(&1) and String.match?(&1, ~r/\A\d{3}\z/))) do
      MapSet.new(numerics)
    else
      raise ArgumentError,
            ":additional_error_numerics must be a list of three-digit strings"
    end
  end

  defp normalize_additional_error_numerics(_numerics) do
    raise ArgumentError, ":additional_error_numerics must be a list of three-digit strings"
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

  defp handle_sasl_authenticate(state, "+", _message), do: send_sasl_initial_response(state)

  defp handle_sasl_authenticate(
         %{sasl_scram: %{phase: :server_first}} = state,
         payload,
         message
       ) do
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
        emit_event(state, {:sasl_scram_error, %{reason: :invalid_base64}}, message)

      {:error, reason} ->
        emit_event(state, {:sasl_scram_error, %{reason: reason}}, message)
    end
  end

  defp handle_sasl_authenticate(
         %{sasl_scram: %{phase: :server_final}} = state,
         payload,
         message
       ) do
    with {:ok, server_final} <- Base.decode64(payload),
         :ok <-
           SASL.verify_scram_sha256_server_final(
             server_final,
             state.sasl_scram.server_signature
           ) do
      %{state | sasl_scram: %{state.sasl_scram | phase: :complete}}
    else
      :error ->
        emit_event(state, {:sasl_scram_error, %{reason: :invalid_base64}}, message)

      {:error, reason} ->
        emit_event(state, {:sasl_scram_error, %{reason: reason}}, message)
    end
  end

  defp handle_sasl_authenticate(state, _payload, _message), do: state

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

    state = emit_event(state, {:sasl_failure, payload}, message)
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

  defp normalize_client_batch_header(state, reference, type, params) when is_list(params) do
    with {:ok, [reference, type | params]} <-
           normalize_outbound_params([reference, type] ++ params),
         :ok <- validate_client_batch_reference(reference),
         :ok <- validate_client_batch_type(type),
         :ok <-
           validate_outbound_message(
             state,
             %Message{command: "BATCH", params: ["+" <> reference, type | params]}
           ) do
      {:ok, reference, type, params}
    end
  end

  defp normalize_client_batch_header(_state, _reference, _type, _params),
    do: {:error, :invalid_param}

  defp validate_client_batch_reference(reference) do
    if String.match?(reference, ~r/\A[A-Za-z0-9-]+\z/),
      do: :ok,
      else: {:error, :invalid_batch_reference}
  end

  defp validate_client_batch_type(type) do
    if type != "" and not String.starts_with?(type, ":") and
         not String.contains?(type, [" ", <<0>>, "\r", "\n"]),
       do: :ok,
       else: {:error, :invalid_batch_type}
  end

  defp prepare_client_batch_messages(state, messages, reference) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      message = ClientCommand.normalize(message)

      result =
        with :ok <- ClientCommand.validate(message, tags: :allow),
             :ok <- reject_nested_client_batch(message),
             :ok <- reject_reserved_client_batch_tag(message) do
          message = %{message | tags: Map.put(message.tags, "batch", reference)}

          with :ok <- validate_outbound_message(state, message) do
            {:ok, message}
          end
        end

      case result do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp reject_nested_client_batch(%Message{command: "BATCH"}),
    do: {:error, :nested_client_batch}

  defp reject_nested_client_batch(_message), do: :ok

  defp reject_reserved_client_batch_tag(%Message{tags: tags}) do
    if Map.has_key?(tags, "batch"), do: {:error, :reserved_client_batch_tag}, else: :ok
  end

  defp send_client_batch(state, reference, type, params, messages) do
    with :ok <- send_message(state, "BATCH", ["+" <> reference, type | params]) do
      case send_client_batch_messages(state, messages) do
        :ok ->
          send_message(state, "BATCH", ["-" <> reference])

        error ->
          _ = send_message(state, "BATCH", ["-" <> reference])
          error
      end
    end
  end

  defp send_client_batch_messages(state, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
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

  defp init_adapter(_state, _adapter, handler) when not is_nil(handler),
    do: {:error, :handler_option_removed}

  defp init_adapter(state, nil, nil), do: {:ok, state}

  defp init_adapter(state, {module, arg}, nil) when is_atom(module),
    do: initialize_adapter(state, module, arg)

  defp init_adapter(_state, _adapter, _handler), do: {:error, :invalid_adapter}

  defp initialize_adapter(state, module, arg) do
    case module.init(arg) do
      {:ok, adapter_state} ->
        {:ok, %{state | adapter: module, adapter_state: adapter_state}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_return, other}}
    end
  rescue
    error -> {:error, {:init_exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp emit(state, event), do: emit(state, event, nil)

  defp emit(state, event, message) do
    envelope = Event.from_legacy!(event, message)

    publications =
      case state.event_mode do
        :legacy -> [event]
        :envelope -> [envelope]
        :both -> [event, envelope]
      end

    Enum.reduce(publications, state, &deliver_event(&2, &1))
  end

  defp deliver_event(state, event) do
    if state.notify, do: send(state.notify, {:ircxd, event})

    case state.adapter do
      nil ->
        state

      module ->
        result = module.handle_event(event, adapter_context(state), state.adapter_state)

        case result do
          {:ok, adapter_state} -> %{state | adapter_state: adapter_state}
          _ -> state
        end
    end
  end

  defp adapter_context(state) do
    %{
      client: self(),
      host: state.host,
      port: state.port,
      tls?: state.tls,
      nick: state.current_nick,
      client_info: client_info(state)
    }
  end

  defp client_info(state) do
    connected? = not is_nil(state.socket)

    status =
      cond do
        state.registered? -> :registered
        connected? -> :connected
        true -> :disconnected
      end

    %Info{
      status: status,
      connected?: connected?,
      registered?: state.registered?,
      host: state.host,
      port: state.port,
      tls?: state.tls,
      transport: state.transport,
      desired_nick: state.nick,
      current_nick: state.current_nick,
      available_caps: state.available_caps,
      active_caps: state.active_caps,
      isupport: state.isupport,
      casemapping: ISupport.casemap(state.isupport)
    }
  end

  defp establish_connected(state, :fresh) do
    with :ok <- maybe_send_webirc(state),
         :ok <- maybe_send_pass(state),
         :ok <- send_message(state, "CAP", ["LS", "302"]),
         :ok <- send_message(state, "NICK", [state.nick]),
         :ok <- send_message(state, "USER", [state.username, "0", "*", state.realname]),
         :ok <- activate_socket(state) do
      {:ok, emit(state, {:connected, connection_metadata(state)})}
    end
  end

  defp establish_connected(state, {:resumed, resume, metadata}) do
    with {:ok, state} <- Resume.restore(resume, state),
         :ok <- activate_socket(state) do
      state =
        state
        |> emit({:connected, connection_metadata(state)})
        |> emit({:resumed, metadata})
        |> emit(:registered)

      {:ok, state}
    end
  end

  defp connection_metadata(state), do: %{host: state.host, port: state.port, tls: state.tls}

  defp transport_adapter(nil), do: SocketTransport

  defp transport_adapter({adapter, _arg}) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :connect, 3) and
         function_exported?(adapter, :send_data, 2) and
         function_exported?(adapter, :activate, 1) and
         function_exported?(adapter, :checkpoint?, 1) and
         function_exported?(adapter, :accepted, 3) and
         function_exported?(adapter, :close, 2) and
         function_exported?(adapter, :handle_info, 2) do
      adapter
    else
      raise ArgumentError, "transport adapter must implement Ircxd.Client.Transport"
    end
  end

  defp transport_adapter(_invalid) do
    raise ArgumentError, ":transport_adapter must be an {adapter_module, init_arg} pair"
  end

  defp transport_adapter_arg(nil, opts),
    do: [tls_options: Keyword.get(opts, :tls_options, [])]

  defp transport_adapter_arg({_adapter, arg}, _opts), do: arg

  defp transport_name(SocketTransport, handle), do: SocketTransport.type(handle)
  defp transport_name(adapter, _handle), do: adapter

  defp reject_connected_handle(adapter, handle, reason) do
    case safe_close(adapter, handle, {:connect_rejected, reason}) do
      :ok -> {:error, reason}
      {:error, close_reason} -> {:error, {:transport_close_failed, close_reason}}
    end
  end

  defp release_transport(%{socket: nil} = state, _reason), do: {:ok, state}

  defp release_transport(state, reason) do
    case safe_close(state.transport_adapter, state.socket, reason) do
      :ok -> {:ok, %{state | socket: nil, transport: nil}}
      {:error, close_reason} -> {:error, close_reason, state}
    end
  end

  defp safe_close(adapter, handle, reason) do
    case adapter.close(handle, reason) do
      :ok -> :ok
      {:error, close_reason} -> {:error, close_reason}
      invalid -> {:error, {:invalid_close_result, invalid}}
    end
  catch
    kind, close_reason -> {:error, {kind, close_reason}}
  end
end
