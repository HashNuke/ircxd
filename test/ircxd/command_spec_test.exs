defmodule Ircxd.CommandSpecTest do
  use ExUnit.Case, async: true

  alias Ircxd.Client.Info
  alias Ircxd.CommandSpec

  @helper_commands ~w(
    ADMIN AUTHENTICATE AWAY BATCH CAP CHATHISTORY CONNECT HELP INFO INVITE ISON ISUPPORT
    JOIN KICK KILL LINKS LIST LUSERS MARKREAD METADATA MODE MONITOR MOTD NAMES
    NICK NOTICE OPER PART PASS PRIVMSG QUIT REDACT REGISTER REHASH RENAME RESTART
    SERVLIST SETNAME SQUERY SQUIT STATS SUMMON TAGMSG TIME TOPIC TRACE USERHOST
    USERS VERIFY VERSION WALLOPS WHO WHOIS WHOWAS
  )

  test "covers the focused client command surface" do
    assert MapSet.new(@helper_commands) == MapSet.new(CommandSpec.commands())

    Enum.each(CommandSpec.commands(), fn command ->
      assert %{known?: true, command: ^command, syntax: syntax} = CommandSpec.get(command)
      assert is_binary(syntax) and syntax != ""
    end)
  end

  test "keeps unknown vendor commands representable without declaring them safe" do
    assert %{
             known?: false,
             command: "VENDORCMD",
             family: :unknown,
             sensitive_positions: []
           } = CommandSpec.classify("vendorcmd", ["one"], %{})
  end

  test "classifies TOPIC and MODE using concrete arguments and ISUPPORT" do
    info = %Info{
      status: :registered,
      connected?: true,
      registered?: true,
      host: "irc.test",
      port: 6697,
      tls?: true,
      transport: :ssl,
      desired_nick: "nick",
      current_nick: "nick",
      available_caps: %{},
      active_caps: MapSet.new(),
      isupport: %{"CHANTYPES" => "#&", "CHANMODES" => "beI,k,l,imnpst", "PREFIX" => "(ov)@+"},
      casemapping: :rfc1459
    }

    assert %{family: :query, result_events: [:topic_empty, :topic_reply, :topic_who_time]} =
             CommandSpec.classify("TOPIC", ["#room"], info)

    assert %{family: :mutation} = CommandSpec.classify("TOPIC", ["#room", ""], info)

    assert %{family: :query, terminal_events: [:ban_list_end]} =
             CommandSpec.classify("MODE", ["#room", "+b"], info)

    assert %{family: :mutation, sensitive_positions: []} =
             CommandSpec.classify("MODE", ["#room", "+b", "*!*@example.test"], info)

    assert %{family: :mutation, sensitive_positions: [2]} =
             CommandSpec.classify("MODE", ["#room", "+k", "secret"], info)

    assert %{family: :mutation, sensitive_positions: [2]} =
             CommandSpec.classify("MODE", ["#room", "-k", "secret"], info)

    assert %{family: :mutation} = CommandSpec.classify("MODE", ["#room", "+o", "Alice"], info)
  end

  test "publishes capabilities, sensitive positions, and completion metadata" do
    assert %{sensitive_positions: [0], family: :registration} = CommandSpec.get("PASS")
    assert %{sensitive_positions: [1], family: :operator} = CommandSpec.get("OPER")
    assert %{required_capabilities: ["setname"]} = CommandSpec.get("SETNAME")

    assert %{
             family: :query,
             required_capabilities: ["draft/extended-isupport"],
             result_events: [:isupport],
             terminal_events: [:isupport_batch]
           } = CommandSpec.get("ISUPPORT")

    assert %{required_capabilities: []} = CommandSpec.classify("AWAY", [], %{})

    assert %{required_capabilities: ["draft/pre-away"]} =
             CommandSpec.classify("AWAY", ["*"], %{})

    assert %{
             required_capabilities: ["draft/chathistory"],
             result_events: [:privmsg, :notice],
             terminal_events: [:batch_end]
           } = CommandSpec.get("CHATHISTORY")

    assert %{result_events: [:who_reply, :whox_reply], terminal_events: [:who_end]} =
             CommandSpec.get("WHO")

    assert %{
             result_events: [:users_start, :users, :users_empty],
             terminal_events: [:users_end, :users_disabled]
           } = CommandSpec.get("USERS")

    assert %{result_events: [:admin_start, :admin_location, :admin_email]} =
             CommandSpec.get("ADMIN")

    for {command, event} <- [
          {"ISON", :ison},
          {"TIME", :time},
          {"USERHOST", :userhost},
          {"VERSION", :version}
        ] do
      assert %{result_events: [^event], terminal_events: [^event]} = CommandSpec.get(command)
    end

    whois_events = CommandSpec.get("WHOIS").result_events

    for event <- [
          :whois_actual_host,
          :whois_bot,
          :whois_certfp,
          :whois_host,
          :whois_modes,
          :whois_registered_nick,
          :whois_secure,
          :whois_special
        ] do
      assert event in whois_events
    end

    assert %{result_events: [:chathistory_target], terminal_events: [:batch_end]} =
             CommandSpec.classify(
               "CHATHISTORY",
               ["TARGETS", "timestamp=1", "timestamp=2", "10"],
               %{}
             )
  end
end
