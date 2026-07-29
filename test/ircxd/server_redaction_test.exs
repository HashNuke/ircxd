defmodule Ircxd.ServerRedactionTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "authors can redact channel messages and remove them from history" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    author_caps = [
      "draft/message-redaction",
      "draft/chathistory",
      "batch",
      "message-tags"
    ]

    reader_caps = author_caps ++ ["echo-message"]

    {:ok, author} = start_client(server, "redaction-author", author_caps)
    {:ok, reader} = start_client(server, "redaction-reader", reader_caps)

    on_exit(fn ->
      stop_if_alive(author)
      stop_if_alive(reader)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.join(author, "#redaction")
    assert_receive {:ircxd, {:join, %{channel: "#redaction"}}}, 2_000
    assert :ok = Client.join(reader, "#redaction")
    assert_receive {:ircxd, {:join, %{channel: "#redaction"}}}, 2_000

    assert :ok = Client.privmsg(author, "#redaction", "remove me")
    assert_receive {:ircxd, {:privmsg, %{body: "remove me", msgid: msgid}}}, 2_000
    refute_receive {:ircxd, {:privmsg, %{body: "remove me"}}}, 250

    assert :ok = Client.redact(author, "#redaction", msgid, "moderation")

    assert_receive {:ircxd,
                    {:redact, %{target: "#redaction", msgid: ^msgid, reason: "moderation"}}},
                   2_000

    assert :ok = Client.chathistory_latest(reader, "#redaction", :latest, 10)
    assert_receive {:ircxd, {:batch_start, %{type: "chathistory"}}}, 2_000
    refute_receive {:ircxd, {:privmsg, %{body: "remove me"}}}, 250
    assert_receive {:ircxd, {:batch_end, _}}, 2_000
  end

  test "rejects redaction attempts from non-authors and non-operators" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    caps = ["draft/message-redaction", "message-tags"]
    {:ok, author} = start_client(server, "redaction-owner", caps)
    {:ok, outsider} = start_client(server, "redaction-outsider", caps)

    on_exit(fn ->
      stop_if_alive(author)
      stop_if_alive(outsider)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.join(author, "#redaction-auth")
    assert_receive {:ircxd, {:join, %{channel: "#redaction-auth"}}}, 2_000
    assert :ok = Client.join(outsider, "#redaction-auth")
    assert_receive {:ircxd, {:join, %{channel: "#redaction-auth"}}}, 2_000

    assert :ok = Client.privmsg(author, "#redaction-auth", "keep me")
    assert_receive {:ircxd, {:privmsg, %{body: "keep me", msgid: msgid}}}, 2_000

    assert :ok = Client.redact(outsider, "#redaction-auth", msgid)

    assert_receive {:ircxd, {:standard_reply, %{command: "REDACT", code: "REDACT_FORBIDDEN"}}},
                   2_000

    refute_receive {:ircxd, {:redact, %{msgid: ^msgid}}}, 250
  end

  defp start_client(server, nick, caps) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      notify: self()
    )
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
