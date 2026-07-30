defmodule Ircxd.ServerInvitePolicyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "only an operator may invite into an invite-only channel" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "invite-op")
    {:ok, bob} = start_client(server, "invite-member")
    {:ok, charlie} = start_client(server, "invite-target")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
      stop_if_alive(charlie)
    end)

    wait_registered(3)
    assert :ok = Client.join(alice, "#invite-policy")
    assert_receive {:ircxd, {:join, %{channel: "#invite-policy"}}}, 2_000
    assert :ok = Client.join(bob, "#invite-policy")
    assert_receive {:ircxd, {:join, %{channel: "#invite-policy"}}}, 2_000

    assert :ok = Client.mode(alice, "#invite-policy", "+i")
    assert_receive {:ircxd, {:mode, %{target: "#invite-policy", modes: "+i"}}}, 2_000

    assert :ok = Client.invite(bob, "invite-target", "#invite-policy")

    assert_receive {:ircxd, {:irc_error, %{code: "482", reason: "You're not channel operator"}}},
                   2_000

    assert :ok = Client.invite(alice, "invite-target", "#invite-policy")

    assert_receive {:ircxd, {:inviting, %{nick: "invite-target", channel: "#invite-policy"}}},
                   2_000

    assert_receive {:ircxd, {:invite, %{target: "invite-target", channel: "#invite-policy"}}},
                   2_000

    assert :ok = Client.join(charlie, "#invite-policy")
    assert_receive {:ircxd, {:join, %{channel: "#invite-policy", nick: "invite-target"}}}, 2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: ["no-implicit-names"],
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

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
