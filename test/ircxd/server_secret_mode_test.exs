defmodule Ircxd.ServerSecretModeTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "secret channels are omitted from LIST for non-members" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "secret-alice")
    {:ok, bob} = start_client(server, "secret-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#secret")
    assert_receive {:ircxd, {:join, %{channel: "#secret"}}}, 2_000
    assert :ok = Client.mode(alice, "#secret", "+s")
    assert_receive {:ircxd, {:mode, %{target: "#secret", modes: "+s"}}}, 2_000

    assert :ok = Client.list(bob)
    assert_receive {:ircxd, {:list_start, _}}, 2_000
    refute_receive {:ircxd, {:list_entry, %{channel: "#secret"}}}, 300
    assert_receive {:ircxd, {:list_end, _}}, 2_000

    assert :ok = Client.list(alice)
    assert_receive {:ircxd, {:list_start, _}}, 2_000
    assert_receive {:ircxd, {:list_entry, %{channel: "#secret", visible: "1"}}}, 2_000
    assert_receive {:ircxd, {:list_end, _}}, 2_000

    assert :ok = Client.names(bob, "#secret")
    refute_receive {:ircxd, {:names, %{channel: "#secret"}}}, 300
    assert_receive {:ircxd, {:names_end, %{channel: "#secret"}}}, 2_000

    assert :ok = Client.raw(bob, "NAMES", [])
    refute_receive {:ircxd, {:names_end, %{channel: "#secret"}}}, 300

    assert :ok = Client.who(bob, "#secret")
    refute_receive {:ircxd, {:who_reply, %{channel: "#secret"}}}, 300
    assert_receive {:ircxd, {:who_end, %{mask: "#secret"}}}, 2_000
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
