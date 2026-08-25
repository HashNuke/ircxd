defmodule Ircxd.CommandSpec do
  @moduledoc """
  Protocol-owned metadata for commands sent by `Ircxd.Client`.

  Specifications describe IRC syntax and response hints. They do not grant
  permission to execute a command and do not promise that a remote server will
  deliver a response.
  """

  alias Ircxd.Client.Info
  alias Ircxd.ISupport

  @commands ~w(
    ADMIN AUTHENTICATE AWAY BATCH CAP CHATHISTORY CONNECT HELP INFO INVITE ISON ISUPPORT
    JOIN KICK KILL LINKS LIST LUSERS MARKREAD METADATA MODE MONITOR MOTD NAMES
    NICK NOTICE OPER PART PASS PRIVMSG QUIT REDACT REGISTER REHASH RENAME RESTART
    SERVLIST SETNAME SQUERY SQUIT STATS SUMMON TAGMSG TIME TOPIC TRACE USERHOST
    USERS VERIFY VERSION WALLOPS WHO WHOIS WHOWAS
  )

  @query_commands ~w(
    ADMIN HELP INFO ISON ISUPPORT LINKS LIST LUSERS MOTD NAMES SERVLIST STATS TIME TRACE
    USERHOST USERS VERSION WHO WHOIS WHOWAS
  )
  @messaging_commands ~w(NOTICE PRIVMSG SQUERY TAGMSG WALLOPS)
  @registration_commands ~w(AUTHENTICATE CAP NICK PASS QUIT REGISTER VERIFY)
  @operator_commands ~w(CONNECT KILL OPER REHASH RESTART SQUIT SUMMON)
  @protocol_commands ~w(BATCH PONG)

  @syntax %{
    "ADMIN" => "[server]",
    "AUTHENTICATE" => "<payload>",
    "AWAY" => "[:message]",
    "BATCH" => "<+reference|-reference> [type] [params...]",
    "CAP" => "<LS|LIST|REQ|END> [capabilities]",
    "CHATHISTORY" => "<LATEST|BEFORE|AFTER|AROUND|BETWEEN|TARGETS> <parameters...>",
    "CONNECT" => "<target-server> <port> [remote-server]",
    "HELP" => "[subject]",
    "INFO" => "[server]",
    "INVITE" => "<nick> <channel>",
    "ISON" => "<nick> [nicks...]",
    "ISUPPORT" => "(no parameters)",
    "JOIN" => "<channels> [keys]",
    "KICK" => "<channel> <nick> [:reason]",
    "KILL" => "<nick> :<comment>",
    "LINKS" => "[remote-server] [mask]",
    "LIST" => "[channels] [server]",
    "LUSERS" => "[mask] [server]",
    "MARKREAD" => "<target> [timestamp]",
    "METADATA" => "<target|SUB> <subcommand-or-keys...>",
    "MODE" => "<target> [modes [mode-params...]]",
    "MONITOR" => "<+|-|C|L|S> [targets]",
    "MOTD" => "[server]",
    "NAMES" => "<target>",
    "NICK" => "<nickname>",
    "NOTICE" => "<targets> :<text>",
    "OPER" => "<name> <password>",
    "PART" => "<channels> [:reason]",
    "PASS" => "<password>",
    "PRIVMSG" => "<targets> :<text>",
    "QUIT" => "[:reason]",
    "REDACT" => "<target> <msgid> [:reason]",
    "REGISTER" => "<account> <email> <password>",
    "REHASH" => "(no parameters)",
    "RENAME" => "<old-channel> <new-channel> [:reason]",
    "RESTART" => "(no parameters)",
    "SERVLIST" => "[mask] [type]",
    "SETNAME" => ":<realname>",
    "SQUERY" => "<service> :<text>",
    "SQUIT" => "<server> :<comment>",
    "STATS" => "[query] [server]",
    "SUMMON" => "<user> [server] [channel]",
    "TAGMSG" => "<target>",
    "TIME" => "[server]",
    "TOPIC" => "<channel> [:topic]",
    "TRACE" => "[target]",
    "USERHOST" => "<nick> [nicks...]",
    "USERS" => "[server]",
    "VERIFY" => "<account> <code>",
    "VERSION" => "[server]",
    "WALLOPS" => ":<text>",
    "WHO" => "<mask> [options]",
    "WHOIS" => "<nick>",
    "WHOWAS" => "<nick> [count]"
  }

  @spec commands() :: [String.t()]
  def commands, do: @commands

  @spec get(String.t()) :: map()
  def get(command) when is_binary(command) do
    command = String.upcase(command)

    if command in @commands do
      %{
        known?: true,
        command: command,
        syntax: Map.fetch!(@syntax, command),
        family: base_family(command),
        required_capabilities: required_capabilities(command),
        relevant_isupport: relevant_isupport(command),
        sensitive_positions: sensitive_positions(command),
        result_events: result_events(command),
        terminal_events: terminal_events(command),
        partial_success?: command in ~w(JOIN KICK NOTICE PRIVMSG),
        affects_client_state?: command in ~w(AWAY CAP NICK QUIT)
      }
    else
      unknown(command)
    end
  end

  @spec classify(String.t(), [String.t()], Info.t() | map()) :: map()
  def classify(command, params, client_info) when is_binary(command) and is_list(params) do
    command = String.upcase(command)

    case {command, params} do
      {"AWAY", ["*"]} ->
        get(command)
        |> Map.put(:required_capabilities, ["draft/pre-away"])

      {"CHATHISTORY", ["TARGETS" | _rest]} ->
        get(command)
        |> Map.merge(%{
          result_events: [:chathistory_target],
          terminal_events: [:batch_end]
        })

      {"TOPIC", [_target]} ->
        get(command)
        |> Map.merge(%{
          family: :query,
          result_events: [:topic_empty, :topic_reply, :topic_who_time],
          terminal_events: []
        })

      {"TOPIC", [_target, _topic]} ->
        Map.put(get(command), :family, :mutation)

      {"MODE", mode_params} ->
        classify_mode(mode_params, isupport(client_info))

      _ ->
        get(command)
    end
  end

  def classify(command, _params, _client_info) when is_binary(command),
    do: get(command)

  defp classify_mode([target], isupport) do
    result = if ISupport.channel?(isupport, target), do: [:channel_mode], else: [:user_mode]
    Map.merge(get("MODE"), %{family: :query, result_events: result, terminal_events: []})
  end

  defp classify_mode([target, modes | params], isupport) do
    if ISupport.channel?(isupport, target) do
      analysis = analyze_channel_modes(String.graphemes(modes), params, isupport)

      Map.merge(get("MODE"), %{
        family: if(analysis.mutation?, do: :mutation, else: :query),
        sensitive_positions: analysis.sensitive_positions,
        result_events: analysis.result_events,
        terminal_events: analysis.terminal_events
      })
    else
      Map.merge(get("MODE"), %{family: :mutation, result_events: [:mode], terminal_events: []})
    end
  end

  defp classify_mode(_params, _isupport), do: get("MODE")

  defp analyze_channel_modes(mode_chars, params, isupport) do
    initial = %{
      sign: "+",
      remaining_params: params,
      next_position: 2,
      mutation?: false,
      sensitive_positions: [],
      result_events: [],
      terminal_events: []
    }

    result =
      Enum.reduce(mode_chars, initial, fn
        sign, acc when sign in ["+", "-"] ->
          %{acc | sign: sign}

        mode, acc ->
          analyze_channel_mode(mode, acc, ISupport.channel_mode_type(isupport, mode))
      end)

    Map.update!(result, :sensitive_positions, &Enum.uniq/1)
  end

  defp analyze_channel_mode(mode, %{remaining_params: []} = acc, :list) do
    {result, terminal} = list_mode_events(mode)

    acc
    |> Map.update!(:result_events, &Enum.uniq(&1 ++ result))
    |> Map.update!(:terminal_events, &Enum.uniq(&1 ++ terminal))
  end

  defp analyze_channel_mode(mode, acc, :list), do: consume_mode_param(mode, acc, true)
  defp analyze_channel_mode(mode, acc, :always_arg), do: consume_mode_param(mode, acc, true)

  defp analyze_channel_mode(mode, %{sign: "+"} = acc, :set_arg),
    do: consume_mode_param(mode, acc, true)

  defp analyze_channel_mode(_mode, acc, _type), do: %{acc | mutation?: true}

  defp consume_mode_param(mode, %{remaining_params: [_value | rest]} = acc, mutation?) do
    sensitive_positions =
      if mode == "k",
        do: acc.sensitive_positions ++ [acc.next_position],
        else: acc.sensitive_positions

    %{
      acc
      | remaining_params: rest,
        next_position: acc.next_position + 1,
        mutation?: acc.mutation? or mutation?,
        sensitive_positions: sensitive_positions,
        result_events: Enum.uniq(acc.result_events ++ [:mode])
    }
  end

  defp consume_mode_param(_mode, acc, mutation?),
    do: %{acc | mutation?: acc.mutation? or mutation?}

  defp list_mode_events("b"), do: {[:ban_list], [:ban_list_end]}
  defp list_mode_events("e"), do: {[:exception_list], [:exception_list_end]}
  defp list_mode_events("I"), do: {[:invite_exception_list], [:invite_exception_list_end]}
  defp list_mode_events(_mode), do: {[:channel_mode], []}

  defp isupport(%Info{isupport: isupport}), do: isupport
  defp isupport(%{isupport: isupport}) when is_map(isupport), do: isupport
  defp isupport(isupport) when is_map(isupport), do: isupport
  defp isupport(_client_info), do: %{}

  defp unknown(command) do
    %{
      known?: false,
      command: command,
      syntax: nil,
      family: :unknown,
      required_capabilities: [],
      relevant_isupport: [],
      sensitive_positions: [],
      result_events: [],
      terminal_events: [],
      partial_success?: false,
      affects_client_state?: false
    }
  end

  defp base_family(command) when command in @query_commands, do: :query
  defp base_family(command) when command in @messaging_commands, do: :messaging
  defp base_family(command) when command in @registration_commands, do: :registration
  defp base_family(command) when command in @operator_commands, do: :operator
  defp base_family(command) when command in @protocol_commands, do: :protocol
  defp base_family(_command), do: :mutation

  defp required_capabilities("CHATHISTORY"), do: ["draft/chathistory"]
  defp required_capabilities("MARKREAD"), do: ["draft/read-marker"]
  defp required_capabilities("METADATA"), do: ["metadata"]
  defp required_capabilities("REDACT"), do: ["draft/message-redaction", "message-tags"]
  defp required_capabilities("REGISTER"), do: ["draft/account-registration"]
  defp required_capabilities("RENAME"), do: ["draft/channel-rename"]
  defp required_capabilities("ISUPPORT"), do: ["draft/extended-isupport"]
  defp required_capabilities("SETNAME"), do: ["setname"]
  defp required_capabilities("TAGMSG"), do: ["message-tags"]
  defp required_capabilities("VERIFY"), do: ["draft/account-registration"]
  defp required_capabilities(_command), do: []

  defp relevant_isupport("JOIN"), do: ["CHANTYPES", "CHANLIMIT", "TARGMAX"]
  defp relevant_isupport("MODE"), do: ["CHANTYPES", "CHANMODES", "PREFIX", "MODES"]

  defp relevant_isupport(command) when command in ~w(NOTICE PRIVMSG),
    do: ["TARGMAX", "MAXTARGETS"]

  defp relevant_isupport(_command), do: []

  defp sensitive_positions("AUTHENTICATE"), do: [0]
  defp sensitive_positions("JOIN"), do: [1]
  defp sensitive_positions("OPER"), do: [1]
  defp sensitive_positions("PASS"), do: [0]
  defp sensitive_positions("REGISTER"), do: [2]
  defp sensitive_positions("VERIFY"), do: [1]
  defp sensitive_positions(_command), do: []

  defp result_events("CHATHISTORY"), do: [:privmsg, :notice]
  defp result_events("ADMIN"), do: [:admin_start, :admin_location, :admin_email]
  defp result_events("HELP"), do: [:help_start, :help]
  defp result_events("INFO"), do: [:info]
  defp result_events("ISON"), do: [:ison]
  defp result_events("ISUPPORT"), do: [:isupport]
  defp result_events("LINKS"), do: [:links]
  defp result_events("LIST"), do: [:list_start, :list_entry]
  defp result_events("LUSERS"), do: [:lusers]
  defp result_events("MOTD"), do: [:motd_start, :motd]
  defp result_events("NAMES"), do: [:names]
  defp result_events("SERVLIST"), do: [:servlist]
  defp result_events("STATS"), do: [:stats_linkinfo, :stats_uptime, :stats_command, :stats_line]
  defp result_events("TIME"), do: [:time]
  defp result_events("TRACE"), do: [:trace]
  defp result_events("USERHOST"), do: [:userhost]
  defp result_events("USERS"), do: [:users_start, :users, :users_empty]
  defp result_events("VERSION"), do: [:version]
  defp result_events("WHO"), do: [:who_reply, :whox_reply]

  defp result_events("WHOIS"),
    do: [
      :whois_user,
      :whois_server,
      :whois_operator,
      :whois_certfp,
      :whois_registered_nick,
      :whois_bot,
      :whois_idle,
      :whois_channels,
      :whois_account,
      :whois_special,
      :whois_actual_host,
      :whois_host,
      :whois_modes,
      :whois_secure
    ]

  defp result_events("WHOWAS"), do: [:whowas_user]
  defp result_events(_command), do: []

  defp terminal_events("CHATHISTORY"), do: [:batch_end]
  defp terminal_events("ADMIN"), do: [:admin_email]
  defp terminal_events("HELP"), do: [:help_end]
  defp terminal_events("INFO"), do: [:info_end]
  defp terminal_events("ISON"), do: [:ison]
  defp terminal_events("ISUPPORT"), do: [:isupport_batch]
  defp terminal_events("LINKS"), do: [:links_end]
  defp terminal_events("LIST"), do: [:list_end]
  defp terminal_events("MOTD"), do: [:motd_end, :motd_missing]
  defp terminal_events("NAMES"), do: [:names_end]
  defp terminal_events("SERVLIST"), do: [:servlist_end]
  defp terminal_events("STATS"), do: [:stats_end]
  defp terminal_events("TIME"), do: [:time]
  defp terminal_events("TRACE"), do: [:trace_end]
  defp terminal_events("USERHOST"), do: [:userhost]
  defp terminal_events("USERS"), do: [:users_end, :users_disabled]
  defp terminal_events("WHO"), do: [:who_end]
  defp terminal_events("WHOIS"), do: [:whois_end]
  defp terminal_events("WHOWAS"), do: [:whowas_end]
  defp terminal_events("VERSION"), do: [:version]
  defp terminal_events(_command), do: []
end
