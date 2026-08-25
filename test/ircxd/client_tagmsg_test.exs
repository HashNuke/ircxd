defmodule Ircxd.ClientTagmsgTest do
  use ExUnit.Case, async: false

  alias Ircxd.ScriptedIrcServer

  test "sends and receives IRCv3 TAGMSG messages" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :message-tags"]

           "CAP REQ message-tags", _state ->
             [":irc.test CAP * ACK :message-tags"]

           "CAP END", _state ->
             [
               ":irc.test 001 nick :Welcome",
               "@+typing=active :alice!a@example.test TAGMSG #elixir",
               "@+typing=paused :alice!a@example.test TAGMSG nick",
               "@+typing=done :alice!a@example.test TAGMSG #elixir"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["message-tags"],
        notify: self()
      )

    assert_receive {:ircxd,
                    {:tagmsg,
                     %{
                       nick: "alice",
                       target: "#elixir",
                       tags: %{"+typing" => "active"}
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:typing,
                     %{
                       nick: "alice",
                       target: "#elixir",
                       status: :active
                     }}},
                   1_000

    assert_receive {:ircxd,
                    {:typing,
                     %{
                       nick: "alice",
                       target: "nick",
                       status: :paused,
                       source_self?: false,
                       target_self?: true
                     }}},
                   1_000

    assert_receive {:ircxd, {:typing, %{nick: "alice", target: "#elixir", status: :done}}},
                   1_000

    assert :ok = Ircxd.Client.typing(client, "#elixir", :done)
    assert_receive {:scripted_irc_line, "@+typing=done TAGMSG #elixir"}, 1_000
  end

  test "validates outbound typing statuses" do
    assert {:error, :invalid_typing_status} = Ircxd.Client.typing(self(), "#elixir", :invalid)
  end

  test "requires message-tags for TAGMSG regardless of tag shape" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state -> [":irc.test CAP * LS :"]
           "CAP END", _state -> [":irc.test 001 nick :Welcome"]
           _line, _state -> []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    for tags <- [%{}, %{"example/tag" => "value"}] do
      assert {:error, {:capability_not_enabled, "message-tags"}} =
               Ircxd.Client.tagmsg(client, "#elixir", tags)
    end

    refute Enum.any?(ScriptedIrcServer.lines(server), &String.contains?(&1, "TAGMSG"))
  end
end
