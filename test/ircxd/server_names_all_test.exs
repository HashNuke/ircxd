defmodule Ircxd.ServerNamesAllTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "answers NAMES without a target for every known channel" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "names-alice")
    {:ok, bob} = start_client(server, "names-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#names")
    assert :ok = Client.join(bob, "#names")
    wait_for_joins(2)

    assert :ok = Client.raw(alice, "NAMES", [])
    assert_receive {:ircxd, {:names, %{channel: "#names", names: names}}}, 2_000
    assert Enum.any?(names, &(&1.nick == "names-alice"))
    assert Enum.any?(names, &(&1.nick == "names-bob"))
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd names client",
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
      {:ircxd, {:join, %{channel: "#names"}}} -> wait_for_joins(remaining - 1)
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
