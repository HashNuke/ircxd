defmodule Ircxd.ServerLabeledResponseTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "frames a multi-message labeled WHOIS as one completed batch" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, requester} =
      start_client(server, "labeled-requester", ["labeled-response", "batch"])

    {:ok, target} = start_client(server, "labeled-target", [])

    on_exit(fn ->
      stop_if_alive(requester)
      stop_if_alive(target)
    end)

    wait_registered_and_capabilities(2, 1)

    assert :ok = Client.labeled_raw(requester, "whois-1", "WHOIS", ["labeled-target"])

    assert_receive {:ircxd, {:whois_user, %{label: "whois-1", batch: batch_ref}}}, 2_000
    assert_receive {:ircxd, {:whois_end, %{label: "whois-1", batch: ^batch_ref}}}, 2_000

    assert_receive {:ircxd,
                    {:labeled_response,
                     %{
                       label: "whois-1",
                       event: {:batch, %{ref: ^batch_ref, events: events}}
                     }}},
                   2_000

    assert Enum.map(events, &elem(&1, 0)) |> List.first() == :whois_user
    assert Enum.map(events, &elem(&1, 0)) |> List.last() == :whois_end

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{label: "whois-1", status: :completed, response_type: :batch}}},
                   2_000

    refute_receive {:ircxd,
                    {:labeled_request,
                     %{label: "whois-1", status: :completed, response_type: :single}}},
                   100
  end

  test "preserves a label on a single WHOIS error" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, requester} =
      start_client(server, "labeled-requester", ["labeled-response", "batch"])

    on_exit(fn -> stop_if_alive(requester) end)
    wait_registered_and_capabilities(1, 1)

    assert :ok = Client.labeled_raw(requester, "missing-1", "WHOIS", ["missing-target"])

    assert_receive {:ircxd,
                    {:irc_error,
                     %{code: "401", label: "missing-1", raw_message: %Ircxd.Message{}}}},
                   2_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{
                       label: "missing-1",
                       status: :failed,
                       response_type: :single,
                       reason: {:irc_error, %{code: "401"}}
                     }}},
                   2_000
  end

  test "preserves a label when WHOIS has no target" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, requester} =
      start_client(server, "labeled-requester", ["labeled-response", "batch"])

    on_exit(fn -> stop_if_alive(requester) end)
    wait_registered_and_capabilities(1, 1)

    assert :ok = Client.labeled_raw(requester, "missing-params", "WHOIS", [])

    assert_receive {:ircxd,
                    {:irc_error,
                     %{code: "461", label: "missing-params", raw_message: %Ircxd.Message{}}}},
                   2_000

    assert_receive {:ircxd,
                    {:labeled_request,
                     %{
                       label: "missing-params",
                       status: :failed,
                       response_type: :single,
                       reason: {:irc_error, %{code: "461"}}
                     }}},
                   2_000
  end

  test "preserves a label on PING responses for labeled-response clients" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} = start_client(server, "labeled-ping", ["labeled-response", "batch"])
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
