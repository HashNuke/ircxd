defmodule Ircxd.ServerLabeledResponseTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "preserves a label on WHOIS replies for labeled-response clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, requester} = start_client(server, "labeled-requester", ["labeled-response"])
    {:ok, target} = start_client(server, "labeled-target", [])

    on_exit(fn ->
      stop_if_alive(requester)
      stop_if_alive(target)
    end)

    wait_registered_and_capabilities(2, 1)

    assert :ok = Client.labeled_raw(requester, "whois-1", "WHOIS", ["labeled-target"])

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{label: "whois-1", event: {:whois_end, %{nick: "labeled-target"}}}}},
                   2_000
  end

  test "preserves a label on PING responses for labeled-response clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "labeled-ping", ["labeled-response"])
    on_exit(fn -> stop_if_alive(client) end)
    wait_registered_and_capabilities(1, 1)

    assert :ok = Client.labeled_raw(client, "ping-1", "PING", ["token-1"])

    assert_receive {:ircxd,
                    {:labeled_response, %{label: "ping-1", event: {:pong, %{token: "token-1"}}}}},
                   2_000
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

  defp wait_registered_and_capabilities(0, 0), do: :ok

  defp wait_registered_and_capabilities(registered, capabilities) do
    receive do
      {:ircxd, :registered} ->
        wait_registered_and_capabilities(registered - 1, capabilities)

      {:ircxd, {:cap_ack, _caps}} ->
        wait_registered_and_capabilities(registered, capabilities - 1)

      _other ->
        wait_registered_and_capabilities(registered, capabilities)
    after
      2_000 -> flunk("clients did not register and negotiate capabilities")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
