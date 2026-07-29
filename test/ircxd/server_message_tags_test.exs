defmodule Ircxd.ServerMessageTagsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  test "preserves tags when fanning tagged PRIVMSG to channel members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "tagged-alice")
    {:ok, bob} = start_client(server, "tagged-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    wait_for_capability_acks(2)
    assert :ok = Client.join(alice, "#tagged")
    assert :ok = Client.join(bob, "#tagged")
    wait_for_joins(2)

    assert :ok = Client.privmsg(alice, "#tagged", "tagged hello", %{"msgid" => "m-1"})
    assert_receive {:ircxd, {:privmsg, %{message: %Message{tags: %{"msgid" => "m-1"}}}}}, 2_000
    assert_receive {:ircxd, {:privmsg, %{message: %Message{tags: %{"msgid" => "m-1"}}}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd tagged message client",
      caps: ["message-tags"],
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

  defp wait_for_capability_acks(0), do: :ok

  defp wait_for_capability_acks(remaining) do
    receive do
      {:ircxd, {:cap_ack, ["message-tags"]}} -> wait_for_capability_acks(remaining - 1)
      _other -> wait_for_capability_acks(remaining)
    after
      2_000 -> flunk("clients did not activate message-tags")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#tagged"}}} -> wait_for_joins(remaining - 1)
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
