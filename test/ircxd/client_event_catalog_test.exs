defmodule Ircxd.ClientEventCatalogTest do
  use ExUnit.Case, async: false

  alias Ircxd.Client.Event
  alias Ircxd.ScriptedIrcServer

  test "publishes a canonical catalog including content, terminal, and derivative events" do
    names = MapSet.new(Event.names())

    assert MapSet.subset?(
             MapSet.new([
               :connected,
               :registered,
               :privmsg,
               :join,
               :names,
               :names_end,
               :who_reply,
               :who_end,
               :irc_error,
               :message,
               :labeled_response,
               :batched,
               :typing,
               :reaction,
               :duplicate_msgid
             ]),
             names
           )

    assert Event.spec(:who_end).terminal?
    assert Event.spec(:names_end).terminal?
    assert Event.spec(:batch_end).terminal?
    assert Event.spec(:time).terminal?
    assert Event.spec(:version).terminal?
    assert Event.spec(:ison).terminal?
    assert Event.spec(:userhost).terminal?
    assert Event.spec(:isupport_batch).terminal?
    assert Event.spec(:ack).terminal?
    assert Event.spec(:labeled_response).terminal?
    assert Event.spec(:users_disabled).terminal?
    refute Event.spec(:users_empty).terminal?
    assert Event.spec(:message).derivative?
    assert Event.spec(:labeled_response).derivative?
    refute Event.spec(:privmsg).derivative?
  end

  test "derives envelope server time and batch references from raw boundaries" do
    time = ~U[2026-08-25 09:00:00Z]

    timed_message = %Ircxd.Message{
      tags: %{"time" => DateTime.to_iso8601(time)},
      source: "irc.test",
      command: "315",
      params: ["nick", "#room", "End of WHO"]
    }

    assert %Event{message: ^timed_message, server_time: ^time} =
             Event.from_legacy!({:who_end, %{raw_message: timed_message}})

    boundary_message = %Ircxd.Message{
      source: "irc.test",
      command: "BATCH",
      params: ["-history"]
    }

    assert %Event{batch: "history", message: ^boundary_message, terminal?: true} =
             Event.from_legacy!(
               {:batch_end, %{ref: "history", batch: %{type: "draft/chathistory"}}},
               boundary_message
             )
  end

  test "supports an opt-in normalized envelope without legacy duplicate content" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :"]

           "CAP END", _state ->
             [
               ":irc.test 001 Nick :Welcome",
               ":alice!user@host PRIVMSG Nick :hello"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, _client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "Nick",
        username: "Nick",
        realname: "Nick",
        events: :envelope,
        notify: self()
      )

    assert_receive {:ircxd, %Event{name: :registered, origin: :internal}}, 1_000

    assert_receive {:ircxd,
                    %Event{
                      name: :privmsg,
                      payload: %{body: "hello", target_self?: true},
                      message: %Ircxd.Message{command: "PRIVMSG"},
                      origin: :message,
                      derivative?: false
                    }},
                   1_000

    refute_receive {:ircxd, {:privmsg, _payload}}, 100
  end
end
