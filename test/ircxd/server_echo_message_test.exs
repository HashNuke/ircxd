defmodule Ircxd.ServerEchoMessageTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "echoes a sender's channel message only when echo-message is negotiated" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, sender} = start_client(server, "echo-sender", [])
    {:ok, receiver} = start_client(server, "echo-receiver", [])

    on_exit(fn ->
      stop_if_alive(sender)
      stop_if_alive(receiver)
    end)

    wait_registered(2)
    assert :ok = Client.join(sender, "#echo")
    assert :ok = Client.join(receiver, "#echo")
    wait_for_joins(2)

    assert :ok = Client.privmsg(sender, "#echo", "without echo")
    assert_receive {:ircxd, {:privmsg, %{body: "without echo"}}}, 2_000
    refute_receive {:ircxd, {:privmsg, %{body: "without echo"}}}, 300

    stop_if_alive(sender)
    {:ok, echo_sender} = start_client(server, "echo-enabled", ["echo-message"])
    on_exit(fn -> stop_if_alive(echo_sender) end)
    wait_registered(1)
    assert :ok = Client.join(echo_sender, "#echo")
    assert_receive {:ircxd, {:join, %{channel: "#echo"}}}, 2_000

    assert :ok = Client.privmsg(echo_sender, "#echo", "with echo")
    assert_receive {:ircxd, {:privmsg, %{body: "with echo"}}}, 2_000
    assert_receive {:ircxd, {:privmsg, %{body: "with echo"}}}, 2_000
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

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      _other -> wait_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#echo"}}} -> wait_for_joins(remaining - 1)
      _other -> wait_for_joins(remaining)
    after
      2_000 -> flunk("clients did not join")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
