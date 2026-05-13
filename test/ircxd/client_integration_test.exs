defmodule Ircxd.ClientIntegrationTest do
  use ExUnit.Case, async: false

  alias Ircxd.RawIrcClient

  @host "127.0.0.1"
  @port 6667
  @channel "#ircxd"

  setup_all do
    case :gen_tcp.connect(String.to_charlist(@host), @port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        flunk("InspIRCd must be running on #{@host}:#{@port}; got #{inspect(reason)}")
    end
  end

  test "connects to InspIRCd, joins a channel, sends, and receives messages" do
    observer_nick = "observer#{System.unique_integer([:positive])}"
    client_nick = "ircxd#{System.unique_integer([:positive])}"

    {:ok, observer} = RawIrcClient.connect(host: @host, port: @port, nick: observer_nick)
    assert {:ok, _line, _seen} = RawIrcClient.join(observer, @channel)

    {:ok, client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: client_nick,
        username: client_nick,
        realname: "Ircxd Test",
        caps: ["message-tags", "server-time", "echo-message"],
        notify: self()
      )

    assert {:ok, caps} =
             wait_for_event(fn
               {:cap_ls, caps} -> {:ok, caps}
               _ -> :cont
             end)

    assert is_map(caps)

    assert {:ok, :registered} =
             wait_for_event(
               fn
                 :registered -> {:ok, :registered}
                 _ -> :cont
               end,
               15_000
             )

    assert {:ok, isupport} =
             wait_for_event(fn
               {:isupport, tokens} when is_map_key(tokens, "CHANTYPES") -> {:ok, tokens}
               _ -> :cont
             end)

    assert isupport["CHANTYPES"] == "#"

    assert :ok = Ircxd.Client.join(client, @channel)
    assert {:ok, join_line, _seen} = RawIrcClient.wait_for(observer, " JOIN :#{@channel}", 5_000)
    assert String.contains?(join_line, client_nick)

    assert :ok = Ircxd.Client.privmsg(client, @channel, "hello from ircxd")

    assert {:ok, privmsg_line, _seen} =
             RawIrcClient.wait_for(observer, " PRIVMSG #{@channel} :hello from ircxd", 5_000)

    assert String.contains?(privmsg_line, client_nick)

    RawIrcClient.privmsg(observer, @channel, "hello back")

    assert_receive {:ircxd,
                    {:privmsg, %{nick: ^observer_nick, target: @channel, body: "hello back"}}},
                   5_000

    RawIrcClient.close(observer)
  end

  test "negotiates IRCv3 echo metadata with InspIRCd" do
    channel = "#ircxdv3#{System.unique_integer([:positive])}"
    client_nick = "ircxdv3#{System.unique_integer([:positive])}"
    requested_caps = ["echo-message", "server-time"]

    {:ok, client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: client_nick,
        username: client_nick,
        realname: "Ircxd IRCv3 Test",
        caps: requested_caps,
        notify: self()
      )

    assert {:ok, caps} =
             wait_for_event(fn
               {:cap_ls, caps} -> {:ok, caps}
               _ -> :cont
             end)

    Enum.each(requested_caps, fn cap -> assert Map.has_key?(caps, cap) end)

    assert {:ok, :registered} = wait_for_event(&match_event(&1, :registered), 15_000)

    assert :ok = Ircxd.Client.join(client, channel)

    assert {:ok, %{nick: ^client_nick, channel: ^channel}} =
             wait_for_event(fn
               {:join, payload} -> {:ok, payload}
               _ -> :cont
             end)

    assert :ok = Ircxd.Client.privmsg(client, channel, "echo metadata from ircxd")

    assert {:ok,
            %{
              nick: ^client_nick,
              target: ^channel,
              body: "echo metadata from ircxd",
              server_time: %DateTime{}
            }} =
             wait_for_event(fn
               {:privmsg, %{nick: ^client_nick, target: ^channel} = payload} -> {:ok, payload}
               _ -> :cont
             end)
  end

  test "receives extended-join metadata from InspIRCd" do
    channel = "#ircxdext#{System.unique_integer([:positive])}"
    client_nick = "ircxdext#{System.unique_integer([:positive])}"
    realname = "Ircxd Extended Join Test"

    {:ok, client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: client_nick,
        username: client_nick,
        realname: realname,
        caps: ["extended-join"],
        notify: self()
      )

    assert {:ok, caps} =
             wait_for_event(fn
               {:cap_ls, caps} -> {:ok, caps}
               _ -> :cont
             end)

    assert Map.has_key?(caps, "extended-join")

    assert {:ok, :registered} = wait_for_event(&match_event(&1, :registered), 15_000)

    assert :ok = Ircxd.Client.join(client, channel)

    assert {:ok,
            %{
              nick: ^client_nick,
              channel: ^channel,
              account: nil,
              realname: ^realname
            }} =
             wait_for_event(fn
               {:join, %{nick: ^client_nick, channel: ^channel} = payload} -> {:ok, payload}
               _ -> :cont
             end)
  end

  test "receives away-notify updates from InspIRCd" do
    channel = "#ircxdaway#{System.unique_integer([:positive])}"
    observer_nick = "ircxdaway#{System.unique_integer([:positive])}"
    raw_nick = "rawaway#{System.unique_integer([:positive])}"

    {:ok, observer} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: observer_nick,
        username: observer_nick,
        realname: "Ircxd Away Notify Test",
        caps: ["away-notify"],
        notify: self()
      )

    assert {:ok, caps} =
             wait_for_event(fn
               {:cap_ls, caps} -> {:ok, caps}
               _ -> :cont
             end)

    assert Map.has_key?(caps, "away-notify")
    assert {:ok, :registered} = wait_for_event(&match_event(&1, :registered), 15_000)
    assert :ok = Ircxd.Client.join(observer, channel)

    assert {:ok, %{nick: ^observer_nick, channel: ^channel}} =
             wait_for_event(fn
               {:join, %{nick: ^observer_nick, channel: ^channel} = payload} -> {:ok, payload}
               _ -> :cont
             end)

    {:ok, raw} = RawIrcClient.connect(host: @host, port: @port, nick: raw_nick)
    assert {:ok, _line, _seen} = RawIrcClient.join(raw, channel)
    assert :ok = RawIrcClient.send_line(raw, "AWAY :checking tests")

    assert {:ok, %{nick: ^raw_nick, away?: true, message: "checking tests"}} =
             wait_for_event(fn
               {:away, %{nick: ^raw_nick} = payload} -> {:ok, payload}
               _ -> :cont
             end)

    assert :ok = RawIrcClient.send_line(raw, "AWAY")

    assert {:ok, %{nick: ^raw_nick, away?: false, message: nil}} =
             wait_for_event(fn
               {:away, %{nick: ^raw_nick} = payload} -> {:ok, payload}
               _ -> :cont
             end)

    RawIrcClient.close(raw)
  end

  test "receives LIST numerics from InspIRCd" do
    channel = "#ircxdlist#{System.unique_integer([:positive])}"
    holder_nick = "listuser#{System.unique_integer([:positive])}"
    client_nick = "ircxdlist#{System.unique_integer([:positive])}"

    {:ok, holder} = RawIrcClient.connect(host: @host, port: @port, nick: holder_nick)
    assert {:ok, _line, _seen} = RawIrcClient.join(holder, channel)

    {:ok, client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: client_nick,
        username: client_nick,
        realname: "Ircxd List Test",
        notify: self()
      )

    assert {:ok, :registered} = wait_for_event(&match_event(&1, :registered), 15_000)
    assert :ok = Ircxd.Client.list(client, channel)

    assert {:ok, %{channel: ^channel, visible: visible}} =
             wait_for_event(fn
               {:list_entry, %{channel: ^channel} = payload} -> {:ok, payload}
               _ -> :cont
             end)

    assert String.to_integer(visible) >= 1

    assert {:ok, %{params: [_nick, "End of channel list."]}} =
             wait_for_event(fn
               {:list_end, payload} -> {:ok, payload}
               _ -> :cont
             end)

    RawIrcClient.close(holder)
  end

  test "receives VERSION and ISON numerics from InspIRCd" do
    holder_nick = "isonuser#{System.unique_integer([:positive])}"
    client_nick = "ircxdquery#{System.unique_integer([:positive])}"

    {:ok, holder} = RawIrcClient.connect(host: @host, port: @port, nick: holder_nick)

    {:ok, client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: client_nick,
        username: client_nick,
        realname: "Ircxd Query Test",
        notify: self()
      )

    assert {:ok, :registered} = wait_for_event(&match_event(&1, :registered), 15_000)

    assert :ok = Ircxd.Client.version(client)

    assert {:ok, %{version: version, server: "irc.local"}} =
             wait_for_event(fn
               {:version, payload} -> {:ok, payload}
               _ -> :cont
             end)

    assert String.contains?(version, "InspIRCd")

    assert :ok = Ircxd.Client.ison(client, [holder_nick, "definitely-not-online"])

    assert {:ok, %{nicks: nicks}} =
             wait_for_event(fn
               {:ison, payload} -> {:ok, payload}
               _ -> :cont
             end)

    assert holder_nick in nicks
    refute "definitely-not-online" in nicks

    RawIrcClient.close(holder)
  end

  test "retries nickname when the requested nick is in use" do
    base_nick = "taken#{System.unique_integer([:positive])}"
    {:ok, holder} = RawIrcClient.connect(host: @host, port: @port, nick: base_nick)

    {:ok, _client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: base_nick,
        username: "retryuser",
        realname: "Retry User",
        notify: self()
      )

    assert {:ok, %{attempted: ^base_nick, next: next_nick}} =
             wait_for_event(
               fn
                 {:nick_in_use, payload} -> {:ok, payload}
                 _ -> :cont
               end,
               15_000
             )

    assert next_nick == "#{base_nick}_"
    assert {:ok, :registered} = wait_for_event(&match_event(&1, :registered), 15_000)

    RawIrcClient.close(holder)
  end

  defp wait_for_event(fun, timeout \\ 5_000) do
    receive do
      {:ircxd, event} ->
        case fun.(event) do
          {:ok, value} -> {:ok, value}
          :cont -> wait_for_event(fun, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp match_event(event, event), do: {:ok, event}
  defp match_event(_event, _expected), do: :cont
end
