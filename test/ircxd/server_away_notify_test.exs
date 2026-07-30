defmodule Ircxd.ServerAwayNotifyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "delivers AWAY changes only to clients with away-notify" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, away_client} = start_client(server, "away-enabled", ["away-notify"])
    {:ok, plain_client} = start_client(server, "away-plain", [])

    on_exit(fn ->
      stop_if_alive(away_client)
      stop_if_alive(plain_client)
    end)

    wait_for_registration_and_capabilities(2, 1)
    assert :ok = Client.join(away_client, "#away-notify")
    assert :ok = Client.join(plain_client, "#away-notify")
    wait_for_joins(2)

    assert :ok = Client.away(away_client, "gone")
    assert_receive {:ircxd, {:now_away, _}}, 2_000
    assert_receive {:ircxd, {:away, %{nick: "away-enabled", message: "gone"}}}, 2_000
    refute_receive {:ircxd, {:away, %{nick: "away-enabled"}}}, 300
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

  defp wait_for_registration_and_capabilities(0, 0), do: :ok

  defp wait_for_registration_and_capabilities(registered, capabilities) do
    receive do
      {:ircxd, :registered} ->
        wait_for_registration_and_capabilities(registered - 1, capabilities)

      {:ircxd, {:cap_ack, _acked}} ->
        wait_for_registration_and_capabilities(registered, capabilities - 1)

      _other ->
        wait_for_registration_and_capabilities(registered, capabilities)
    after
      2_000 -> flunk("clients did not complete registration and capability negotiation")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#away-notify"}}} -> wait_for_joins(remaining - 1)
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
