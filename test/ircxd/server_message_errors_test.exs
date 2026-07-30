defmodule Ircxd.ServerMessageErrorsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns standard errors for malformed PRIVMSG parameters" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "message-errors",
        username: "user",
        realname: "Ircxd message errors client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.raw(client, "PRIVMSG", [])
    assert_receive {:ircxd, {:irc_error, %{code: "411", reason: "No recipient given"}}}, 2_000

    assert :ok = Client.raw(client, "PRIVMSG", ["#missing"])
    assert_receive {:ircxd, {:irc_error, %{code: "412", reason: "No text to send"}}}, 2_000
  end

  test "does not generate error replies for malformed NOTICE" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "notice-errors",
        username: "user",
        realname: "Ircxd notice errors client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.raw(client, "NOTICE", [])
    refute_receive {:ircxd, {:irc_error, _error}}, 250
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
