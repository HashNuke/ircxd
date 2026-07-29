defmodule Ircxd.ServerTagmsgPolicyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "TAGMSG follows channel membership and +n external-message policy" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "tag-policy-alice")
    {:ok, bob} = start_client(server, "tag-policy-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_ready(2, 2)
    assert :ok = Client.join(alice, "#tag-policy")
    assert_receive {:ircxd, {:join, %{channel: "#tag-policy"}}}, 2_000

    assert :ok = Client.tagmsg(bob, "#tag-policy", %{"+typing" => "active"})
    refute_receive {:ircxd, {:tagmsg, %{target: "#tag-policy"}}}, 300

    assert :ok = Client.mode(alice, "#tag-policy", "-n")
    assert_receive {:ircxd, {:mode, %{target: "#tag-policy", modes: "-n"}}}, 2_000

    assert :ok = Client.tagmsg(bob, "#tag-policy", %{"+typing" => "active"})

    assert_receive {:ircxd, {:tagmsg, %{target: "#tag-policy", tags: %{"+typing" => "active"}}}},
                   2_000
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd #{nick} client",
      caps: ["message-tags", "no-implicit-names"],
      notify: self()
    )
  end

  defp wait_ready(0, 0), do: :ok

  defp wait_ready(registered, capabilities) do
    receive do
      {:ircxd, :registered} -> wait_ready(registered - 1, capabilities)
      {:ircxd, {:cap_ack, _caps}} -> wait_ready(registered, capabilities - 1)
      _other -> wait_ready(registered, capabilities)
    after
      2_000 -> flunk("clients did not register and negotiate message-tags")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
