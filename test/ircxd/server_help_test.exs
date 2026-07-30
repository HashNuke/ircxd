defmodule Ircxd.ServerHelpTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "returns configured HELP text with start and end numerics" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        help: %{
          "JOIN" => ["JOIN <channel>", "Join a channel"]
        }
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "help-client",
        username: "help-client",
        realname: "Ircxd help client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Client.help(client, "JOIN")
    assert_receive {:ircxd, {:help_start, %{subject: "JOIN"}}}, 2_000
    assert_receive {:ircxd, {:help, %{subject: "JOIN", text: "JOIN <channel>"}}}, 2_000
    assert_receive {:ircxd, {:help, %{subject: "JOIN", text: "Join a channel"}}}, 2_000
    assert_receive {:ircxd, {:help_end, %{subject: "JOIN"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
