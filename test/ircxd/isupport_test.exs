defmodule Ircxd.ISupportTest do
  use ExUnit.Case, async: true

  alias Ircxd.ISupport

  test "parses RPL_ISUPPORT tokens" do
    assert %{
             "CHANTYPES" => "#&",
             "NICKLEN" => "30",
             "SAFELIST" => true,
             "EXCEPTS" => false
           } =
             ISupport.parse_params([
               "nick",
               "CHANTYPES=#&",
               "NICKLEN=30",
               "SAFELIST",
               "-EXCEPTS",
               "are supported by this server"
             ])
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

  test "parses CHANMODES into argument type groups" do
    assert %{
             type_a: "beI",
             type_b: "kfL",
             type_c: "lj",
             type_d: "psmntirRcOAQKVCuzNSMTGZ",
             extra: ["z"]
           } =
             ISupport.chanmodes(%{"CHANMODES" => "beI,kfL,lj,psmntirRcOAQKVCuzNSMTGZ,z"})
  end

  test "parses CHANLIMIT and MAXLIST limit pairs" do
    assert %{"#" => 70, "&" => :unlimited} =
             ISupport.chanlimit(%{"CHANLIMIT" => "#:70,&:"})

    assert %{"#" => 50, "&" => 50} = ISupport.chanlimit(%{"CHANLIMIT" => "#&:50"})

    assert %{"beI" => 100, "q" => 50} = ISupport.maxlist(%{"MAXLIST" => "beI:100,q:50"})
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

  test "reads typed integer, character-list, and flag values" do
    isupport = %{
      "CHANTYPES" => "#&",
      "STATUSMSG" => "@+",
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

    assert ISupport.characters(isupport, "CHANTYPES") == ["#", "&"]
    assert ISupport.characters(isupport, "STATUSMSG") == ["@", "+"]
    assert ISupport.characters(isupport, "MISSING") == []

    assert ISupport.enabled?(isupport, "SAFELIST")
    refute ISupport.enabled?(isupport, "EXCEPTS")
    refute ISupport.enabled?(isupport, "MISSING")
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
