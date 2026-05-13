defmodule Ircxd.ISupportTest do
  use ExUnit.Case, async: true

  alias Ircxd.ISupport

  test "parses RPL_ISUPPORT tokens" do
    assert %{
             "CHANTYPES" => "#&",
             "NICKLEN" => "30",
             "NETWORK" => "Example Network",
             "ESCAPED" => "a=b\\c",
             "SAFELIST" => true,
             "EXCEPTS" => false
           } =
             ISupport.parse_params([
               "nick",
               "CHANTYPES=#&",
               "NICKLEN=30",
               "NETWORK=Example\\x20Network",
               "ESCAPED=a\\x3Db\\x5Cc",
               "SAFELIST",
               "-EXCEPTS",
               "are supported by this server"
             ])
  end

  test "leaves malformed ISUPPORT value escapes untouched" do
    assert {"BAD", "a\\x2"} = ISupport.parse_token("BAD=a\\x2")
    assert {"BAD", "a\\xZZ"} = ISupport.parse_token("BAD=a\\xZZ")
  end

  test "treats empty ISUPPORT values as valueless tokens" do
    assert {"MODES", true} = ISupport.parse_token("MODES=")
    assert {"SILENCE", true} = ISupport.parse_token("SILENCE=")
    assert {"CHANTYPES", ""} = ISupport.parse_token("CHANTYPES=")

    assert %{"MODES" => true, "SILENCE" => true} =
             ISupport.parse_params([
               "nick",
               "MODES=",
               "SILENCE=",
               "are supported by this server"
             ])

    assert ISupport.mode_limit(%{"MODES" => true}) == :unlimited
    assert ISupport.silence_limit(%{"SILENCE" => true}) == :unlimited
  end

  test "parses PREFIX mode to membership prefix mappings" do
    assert [
             %{mode: "q", prefix: "~"},
             %{mode: "a", prefix: "&"},
             %{mode: "o", prefix: "@"},
             %{mode: "h", prefix: "%"},
             %{mode: "v", prefix: "+"}
           ] = ISupport.prefix_modes(%{"PREFIX" => "(qaohv)~&@%+"})

    assert [%{mode: "o", prefix: "@"}, %{mode: "v", prefix: "+"}] =
             ISupport.prefix_modes(%{})

    assert [] = ISupport.prefix_modes(%{"PREFIX" => true})
  end

  test "finds membership prefixes and modes from PREFIX" do
    isupport = %{"PREFIX" => "(qaohv)~&@%+"}

    assert ISupport.prefix_for_mode(isupport, "q") == "~"
    assert ISupport.prefix_for_mode(isupport, "o") == "@"
    assert ISupport.prefix_for_mode(isupport, "v") == "+"
    assert ISupport.prefix_for_mode(isupport, "z") == nil
    assert ISupport.prefix_for_mode(%{}, "o") == "@"
    assert ISupport.prefix_for_mode(isupport, nil) == nil
    assert ISupport.prefix_for_mode(isupport, "ov") == nil

    assert ISupport.mode_for_prefix(isupport, "~") == "q"
    assert ISupport.mode_for_prefix(isupport, "@") == "o"
    assert ISupport.mode_for_prefix(isupport, "+") == "v"
    assert ISupport.mode_for_prefix(isupport, "!") == nil
    assert ISupport.mode_for_prefix(%{}, "+") == "v"
    assert ISupport.mode_for_prefix(isupport, nil) == nil
    assert ISupport.mode_for_prefix(isupport, "@+") == nil
  end

  test "parses CHANMODES into argument type groups" do
    assert %{
             type_a: "beI",
             type_b: "kfL",
             type_c: "lj",
             type_d: "psmntirRcOAQKVCuzNSMTGZ",
             extra: ["z"]
           } =
             ISupport.chanmodes(%{"CHANMODES" => "beI,kfL,lj,psmntirRcOAQKVCuzNSMTGZ,z"})

    assert %{type_a: "b", type_b: "k", type_c: "l", type_d: "imnpst", extra: []} =
             ISupport.chanmodes(%{})
  end

  test "classifies concrete channel modes from CHANMODES" do
    isupport = %{"CHANMODES" => "beI,kfL,lj,psmntirRcOAQKVCuzNSMTGZ", "PREFIX" => "(ov)@+"}

    assert ISupport.channel_mode_type(isupport, "b") == :list
    assert ISupport.channel_mode_type(isupport, "I") == :list
    assert ISupport.channel_mode_type(isupport, "k") == :always_arg
    assert ISupport.channel_mode_type(isupport, "L") == :always_arg
    assert ISupport.channel_mode_type(isupport, "o") == :always_arg
    assert ISupport.channel_mode_type(isupport, "v") == :always_arg
    assert ISupport.channel_mode_type(isupport, "l") == :set_arg
    assert ISupport.channel_mode_type(isupport, "j") == :set_arg
    assert ISupport.channel_mode_type(isupport, "p") == :never_arg
    assert ISupport.channel_mode_type(isupport, "m") == :never_arg
    assert ISupport.channel_mode_type(isupport, "w") == nil
    assert ISupport.channel_mode_type(isupport, nil) == nil
    assert ISupport.channel_mode_type(isupport, "be") == nil

    assert ISupport.channel_mode_type(%{}, "b") == :list
    assert ISupport.channel_mode_type(%{}, "k") == :always_arg
    assert ISupport.channel_mode_type(%{}, "l") == :set_arg
    assert ISupport.channel_mode_type(%{}, "i") == :never_arg
  end

  test "parses CHANLIMIT and MAXLIST limit pairs" do
    assert %{"#" => 70, "&" => :unlimited} =
             ISupport.chanlimit(%{"CHANLIMIT" => "#:70,&:"})

    assert %{"#" => 50, "&" => 50} = ISupport.chanlimit(%{"CHANLIMIT" => "#&:50"})

    assert %{"beI" => 100, "q" => 50} = ISupport.maxlist(%{"MAXLIST" => "beI:100,q:50"})
  end

  test "finds list limits for concrete channel modes" do
    isupport = %{"MAXLIST" => "beI:100,q:50,x:"}

    assert ISupport.list_limit(isupport, "b") == 100
    assert ISupport.list_limit(isupport, "e") == 100
    assert ISupport.list_limit(isupport, "I") == 100
    assert ISupport.list_limit(isupport, "q") == 50
    assert ISupport.list_limit(isupport, "x") == :unlimited
    assert ISupport.list_limit(isupport, "z") == nil
    assert ISupport.list_limit(%{}, "b") == nil
    assert ISupport.list_limit(isupport, nil) == nil
    assert ISupport.list_limit(isupport, "be") == nil
  end

  test "finds channel limits for concrete channel names" do
    isupport = %{"CHANLIMIT" => "#:70,&:,!:"}

    assert ISupport.channel_limit(isupport, "#elixir") == 70
    assert ISupport.channel_limit(isupport, "&local") == :unlimited
    assert ISupport.channel_limit(isupport, "!safe") == :unlimited
    assert ISupport.channel_limit(isupport, "+modeless") == nil
    assert ISupport.channel_limit(%{}, "#default") == nil
    assert ISupport.channel_limit(isupport, nil) == nil
  end

  test "parses TARGMAX command target limits case-insensitively" do
    assert %{"JOIN" => :unlimited, "PRIVMSG" => 3, "WHOIS" => 1} =
             ISupport.targmax(%{"TARGMAX" => "privmsg:3,WHOIS:1,JOIN:"})
  end

  test "checks command target limits from TARGMAX" do
    isupport = %{"TARGMAX" => "privmsg:3,WHOIS:1,JOIN:"}

    assert ISupport.target_limit(isupport, "privmsg") == 3
    assert ISupport.target_limit(isupport, "WHOIS") == 1
    assert ISupport.target_limit(isupport, "join") == :unlimited
    assert ISupport.target_limit(isupport, "NOTICE") == nil

    assert ISupport.target_allowed?(isupport, "PRIVMSG", 3)
    refute ISupport.target_allowed?(isupport, "PRIVMSG", 4)
    assert ISupport.target_allowed?(isupport, "JOIN", 100)
    assert ISupport.target_allowed?(isupport, "NOTICE", 10)
    refute ISupport.target_allowed?(isupport, "WHOIS", -1)
  end

  test "uses MAXTARGETS for legacy PRIVMSG and NOTICE target limits" do
    isupport = %{"MAXTARGETS" => "4"}

    assert ISupport.max_targets(isupport) == 4
    assert ISupport.max_targets(%{"MAXTARGETS" => true}) == nil
    assert ISupport.max_targets(%{"MAXTARGETS" => "0"}) == nil
    assert ISupport.max_targets(%{}) == nil

    assert ISupport.target_limit(isupport, "PRIVMSG") == 4
    assert ISupport.target_limit(isupport, "notice") == 4
    assert ISupport.target_limit(isupport, "JOIN") == nil

    assert ISupport.target_allowed?(isupport, "PRIVMSG", 4)
    refute ISupport.target_allowed?(isupport, "PRIVMSG", 5)

    assert ISupport.target_allowed?(
             %{"TARGMAX" => "PRIVMSG:2", "MAXTARGETS" => "4"},
             "PRIVMSG",
             2
           )

    refute ISupport.target_allowed?(
             %{"TARGMAX" => "PRIVMSG:2", "MAXTARGETS" => "4"},
             "PRIVMSG",
             3
           )
  end

  test "reads channel MODE command limits" do
    assert ISupport.mode_limit(%{"MODES" => "4"}) == 4
    assert ISupport.mode_limit(%{"MODES" => "20"}) == 20
    assert ISupport.mode_limit(%{"MODES" => true}) == :unlimited
    assert ISupport.mode_limit(%{"MODES" => "0"}) == nil
    assert ISupport.mode_limit(%{"MODES" => "-1"}) == nil
    assert ISupport.mode_limit(%{"MODES" => "abc"}) == nil
    assert ISupport.mode_limit(%{}) == 3
  end

  test "reads SILENCE list limits" do
    assert ISupport.silence_limit(%{"SILENCE" => "15"}) == 15
    assert ISupport.silence_limit(%{"SILENCE" => "32"}) == 32
    assert ISupport.silence_limit(%{"SILENCE" => true}) == :unlimited
    assert ISupport.silence_limit(%{"SILENCE" => false}) == nil
    assert ISupport.silence_limit(%{"SILENCE" => "0"}) == nil
    assert ISupport.silence_limit(%{"SILENCE" => "-1"}) == nil
    assert ISupport.silence_limit(%{"SILENCE" => "abc"}) == nil
    assert ISupport.silence_limit(%{}) == nil
  end

  test "reads typed integer, character-list, and flag values" do
    isupport = %{
      "CHANTYPES" => "#&",
      "STATUSMSG" => "@+",
      "NETWORK" => "Example Network",
      "NICKLEN" => "30",
      "CHANNELLEN" => "64",
      "SAFELIST" => true,
      "EXCEPTS" => false,
      "BADLEN" => "abc"
    }

    assert ISupport.integer(isupport, "NICKLEN") == 30
    assert ISupport.integer(isupport, "CHANNELLEN") == 64
    assert ISupport.integer(isupport, "BADLEN") == nil
    assert ISupport.integer(isupport, "MISSING", 9) == 9

    assert ISupport.network_name(isupport) == "Example Network"
    assert ISupport.network_name(%{"NETWORK" => ""}) == nil
    assert ISupport.network_name(%{"NETWORK" => true}) == nil
    assert ISupport.network_name(%{}) == nil

    assert ISupport.bot_mode(%{"BOT" => "b"}) == "b"
    assert ISupport.bot_mode(%{"BOT" => "B"}) == "B"
    assert ISupport.bot_mode(%{"BOT" => true}) == nil
    assert ISupport.bot_mode(%{"BOT" => false}) == nil
    assert ISupport.bot_mode(%{"BOT" => ""}) == nil
    assert ISupport.bot_mode(%{"BOT" => "bot"}) == nil
    assert ISupport.bot_mode(%{}) == nil

    assert ISupport.characters(isupport, "CHANTYPES") == ["#", "&"]
    assert ISupport.characters(isupport, "STATUSMSG") == ["@", "+"]
    assert ISupport.characters(isupport, "MISSING") == []

    assert ISupport.enabled?(isupport, "SAFELIST")
    refute ISupport.enabled?(isupport, "EXCEPTS")
    refute ISupport.enabled?(isupport, "MISSING")
  end

  test "reads ELIST list extension flags case-insensitively" do
    isupport = %{"ELIST" => "MU"}

    assert ISupport.elist(isupport) == ["m", "u"]
    assert ISupport.elist(%{"ELIST" => true}) == []
    assert ISupport.elist(%{}) == []

    assert ISupport.list_extension?(isupport, "M")
    assert ISupport.list_extension?(isupport, "m")
    assert ISupport.list_extension?(isupport, "u")
    refute ISupport.list_extension?(isupport, "t")
    refute ISupport.list_extension?(%{}, "m")
    refute ISupport.list_extension?(isupport, nil)
    refute ISupport.list_extension?(isupport, "mu")
  end

  test "reads ban-exception and invite-exception modes" do
    assert ISupport.exception_mode(%{"EXCEPTS" => true}) == "e"
    assert ISupport.exception_mode(%{"EXCEPTS" => "q"}) == "q"
    assert ISupport.exception_mode(%{"EXCEPTS" => false}) == nil
    assert ISupport.exception_mode(%{"EXCEPTS" => "ex"}) == nil
    assert ISupport.exception_mode(%{}) == nil

    assert ISupport.invite_exception_mode(%{"INVEX" => true}) == "I"
    assert ISupport.invite_exception_mode(%{"INVEX" => "j"}) == "j"
    assert ISupport.invite_exception_mode(%{"INVEX" => false}) == nil
    assert ISupport.invite_exception_mode(%{"INVEX" => "IJ"}) == nil
    assert ISupport.invite_exception_mode(%{}) == nil
  end

  test "parses EXTBAN prefix and type letters" do
    assert ISupport.extban(%{"EXTBAN" => "$,ARar"}) == %{prefix: "$", types: ["A", "R", "a", "r"]}

    assert ISupport.extban(%{"EXTBAN" => "~,qjncrRa"}) == %{
             prefix: "~",
             types: ["q", "j", "n", "c", "r", "R", "a"]
           }

    assert ISupport.extban(%{"EXTBAN" => ",ABC"}) == %{prefix: "", types: ["A", "B", "C"]}
    assert ISupport.extban(%{"EXTBAN" => true}) == nil
    assert ISupport.extban(%{"EXTBAN" => "$,"}) == nil
    assert ISupport.extban(%{"EXTBAN" => "$,ab,cd"}) == nil
    assert ISupport.extban(%{"EXTBAN" => "$$,a"}) == nil
    assert ISupport.extban(%{}) == nil

    assert ISupport.extban_type?(%{"EXTBAN" => "$,ARar"}, "R")
    assert ISupport.extban_type?(%{"EXTBAN" => ",ABC"}, "A")
    refute ISupport.extban_type?(%{"EXTBAN" => "$,ARar"}, "z")
    refute ISupport.extban_type?(%{"EXTBAN" => "$,ARar"}, nil)
    refute ISupport.extban_type?(%{"EXTBAN" => "$,ARar"}, "AR")
  end

  test "reads positive length-limit values for stable ISUPPORT tokens" do
    isupport = %{
      "AWAYLEN" => "160",
      "CHANNELLEN" => "64",
      "HOSTLEN" => "63",
      "KICKLEN" => "255",
      "NICKLEN" => "30",
      "TOPICLEN" => "390",
      "USERLEN" => "10",
      "BADLEN" => "0",
      "NONLEN" => "20"
    }

    assert ISupport.length_limit(isupport, "AWAYLEN") == 160
    assert ISupport.length_limit(isupport, "channellen") == 64
    assert ISupport.length_limit(isupport, "HOSTLEN") == 63
    assert ISupport.length_limit(isupport, "KICKLEN") == 255
    assert ISupport.length_limit(isupport, "NICKLEN") == 30
    assert ISupport.length_limit(isupport, "TOPICLEN") == 390
    assert ISupport.length_limit(isupport, "USERLEN") == 10
    assert ISupport.length_limit(isupport, "BADLEN") == nil
    assert ISupport.length_limit(isupport, "NONLEN") == nil
    assert ISupport.length_limit(isupport, "MISSING") == nil
    assert ISupport.length_limit(isupport, nil) == nil
    assert ISupport.length_limit(%{"NICKLEN" => true}, "NICKLEN") == nil
    assert ISupport.length_limit(%{"NICKLEN" => "-1"}, "NICKLEN") == nil
  end

  test "derives IRC casemapping from ISUPPORT tokens" do
    assert ISupport.casemap(%{"CASEMAPPING" => "ascii"}) == :ascii
    assert ISupport.casemap(%{"CASEMAPPING" => "rfc1459"}) == :rfc1459
    assert ISupport.casemap(%{"CASEMAPPING" => "strict-rfc1459"}) == :strict_rfc1459
    assert ISupport.casemap(%{"CASEMAPPING" => "unknown"}) == :rfc1459
    assert ISupport.casemap(%{}) == :rfc1459
    assert ISupport.casemap(%{"CASEMAPPING" => true}) == :rfc1459
  end

  test "compares IRC names using ISUPPORT casemapping" do
    assert ISupport.equal?(%{"CASEMAPPING" => "rfc1459"}, "Nick[", "nick{")
    assert ISupport.equal?(%{"CASEMAPPING" => "rfc1459"}, "Nick~", "nick^")
    assert ISupport.equal?(%{"CASEMAPPING" => "strict-rfc1459"}, "Nick[", "nick{")
    refute ISupport.equal?(%{"CASEMAPPING" => "strict-rfc1459"}, "Nick~", "nick^")
    refute ISupport.equal?(%{"CASEMAPPING" => "ascii"}, "Nick[", "nick{")
    assert ISupport.equal?(%{}, "Nick[", "nick{")
  end

  test "detects channel targets from ISUPPORT CHANTYPES" do
    assert ISupport.channel?(%{"CHANTYPES" => "#&"}, "#elixir")
    assert ISupport.channel?(%{"CHANTYPES" => "#&"}, "&local")
    refute ISupport.channel?(%{"CHANTYPES" => "#&"}, "!safe")

    assert ISupport.channel?(%{"CHANTYPES" => "#&!"}, "!safe")
    assert ISupport.channel?(%{}, "#default")
    assert ISupport.channel?(%{}, "&default")
    refute ISupport.channel?(%{}, "+modeless")
    refute ISupport.channel?(%{"CHANTYPES" => true}, "#bad-token")
    refute ISupport.channel?(%{"CHANTYPES" => ""}, "#no-channel-types")
    refute ISupport.channel?(%{"CHANTYPES" => "#"}, nil)
  end

  test "detects status-message channel targets from ISUPPORT STATUSMSG" do
    isupport = %{"CHANTYPES" => "#&", "STATUSMSG" => "@+"}

    assert ISupport.status_target?(isupport, "@#elixir")
    assert ISupport.status_target?(isupport, "+&local")
    refute ISupport.status_target?(isupport, "%#elixir")
    refute ISupport.status_target?(isupport, "@nick")
    refute ISupport.status_target?(%{"CHANTYPES" => "#"}, "@#elixir")
    refute ISupport.status_target?(%{"STATUSMSG" => true}, "@#bad-token")
    refute ISupport.status_target?(isupport, nil)
  end
end
