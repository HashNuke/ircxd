defmodule Ircxd.ServerInviteNotifyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "advertises invite-notify and notifies opted-in channel members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    capable_notify = forwarder(self(), :capable)
    legacy_notify = forwarder(self(), :legacy)

    on_exit(fn ->
      Process.exit(capable_notify, :normal)
      Process.exit(legacy_notify, :normal)
    end)

    {:ok, inviter} = start_client(server, "invite-notify-op", self(), ["no-implicit-names"])

    {:ok, capable} =
      start_client(server, "invite-notify-member", capable_notify, [
        "invite-notify",
        "no-implicit-names"
      ])

    {:ok, legacy} =
      start_client(server, "invite-notify-legacy", legacy_notify, ["no-implicit-names"])

    {:ok, target} = start_client(server, "invite-notify-target", self(), ["no-implicit-names"])

    on_exit(fn ->
      stop_if_alive(inviter)
      stop_if_alive(capable)
      stop_if_alive(legacy)
      stop_if_alive(target)
    end)

    wait_registered(4)
    assert :ok = Client.join(inviter, "#invite-notify")
    assert :ok = Client.join(capable, "#invite-notify")
    assert :ok = Client.join(legacy, "#invite-notify")
    assert_receive {:ircxd, {:join, %{channel: "#invite-notify"}}}, 2_000

    assert :ok = Client.invite(inviter, "invite-notify-target", "#invite-notify")

    assert_receive {:ircxd, {:inviting, %{channel: "#invite-notify"}}}, 2_000

    assert_receive {:capable,
                    {:ircxd,
                     {:invite, %{target: "invite-notify-target", channel: "#invite-notify"}}}},
                   2_000

    assert_receive {:ircxd,
                    {:invite, %{target: "invite-notify-target", channel: "#invite-notify"}}},
                   2_000

    refute_receive {:legacy, {:ircxd, {:invite, _}}}, 300
  end

  defp start_client(server, nick, notify, caps) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: caps,
      notify: notify
    )
  end

  defp forwarder(parent, label) do
    spawn_link(fn -> forward_events(parent, label) end)
  end

  defp forward_events(parent, label) do
    receive do
      message ->
        send(parent, {label, message})
        forward_events(parent, label)
    end
  end

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      {:capable, {:ircxd, :registered}} -> wait_registered(remaining - 1)
      {:legacy, {:ircxd, :registered}} -> wait_registered(remaining - 1)
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
