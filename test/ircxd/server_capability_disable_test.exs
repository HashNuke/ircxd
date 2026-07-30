defmodule Ircxd.ServerCapabilityDisableTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "disables an active capability and changes sender echo behavior" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, sender} = start_client(server, "cap-sender", ["echo-message", "no-implicit-names"])

    on_exit(fn ->
      stop_if_alive(sender)
    end)

    wait_for_registered_and_capability()
    {:ok, receiver} = start_client(server, "cap-receiver", ["no-implicit-names"])
    on_exit(fn -> stop_if_alive(receiver) end)
    wait_for_registered()
    assert :ok = Client.join(sender, "#capabilities")
    assert :ok = Client.join(receiver, "#capabilities")
    assert_receive {:ircxd, {:join, %{channel: "#capabilities"}}}, 2_000
    assert_receive {:ircxd, {:join, %{channel: "#capabilities"}}}, 2_000

    assert :ok = Client.disable_capabilities(sender, ["echo-message"])
    assert_receive {:ircxd, {:cap_ack, ["-echo-message"]}}, 2_000

    assert :ok = Client.privmsg(sender, "#capabilities", "no longer echoed")
    assert_receive {:ircxd, {:privmsg, %{body: "no longer echoed"}}}, 2_000
    refute_receive {:ircxd, {:privmsg, %{body: "no longer echoed"}}}, 300
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

  defp wait_for_registered_and_capability do
    receive do
      {:ircxd, :registered} -> wait_for_cap_ack()
      _other -> wait_for_registered_and_capability()
    after
      2_000 -> flunk("sender did not register")
    end
  end

  defp wait_for_cap_ack do
    receive do
      {:ircxd, {:cap_ack, caps}} when is_list(caps) ->
        if "echo-message" in caps, do: :ok, else: wait_for_cap_ack()

      _other ->
        wait_for_cap_ack()
    after
      2_000 -> flunk("sender did not negotiate echo-message")
    end
  end

  defp wait_for_registered do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_for_registered()
    after
      2_000 -> flunk("receiver did not register")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
