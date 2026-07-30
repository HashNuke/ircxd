defmodule Ircxd.ServerBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Message, Server}

  test "relays client batches with start and end framing" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, sender} = start_client(server, "batch-sender", ["batch", "message-tags"], self())
    {:ok, receiver} = start_client(server, "batch-receiver", ["batch", "message-tags"], self())

    on_exit(fn ->
      stop_if_alive(sender)
      stop_if_alive(receiver)
    end)

    assert_receive {:ircxd, :registered}, 2_000
    assert_receive {:ircxd, :registered}, 2_000

    assert :ok = Client.join(sender, "#batch")
    assert_receive {:ircxd, {:join, %{channel: "#batch"}}}, 2_000
    assert :ok = Client.join(receiver, "#batch")
    assert_receive {:ircxd, {:join, %{channel: "#batch"}}}, 2_000

    message = %Message{command: "PRIVMSG", params: ["#batch", "inside batch"]}

    assert :ok =
             Client.client_batch(sender, "b1", "draft/example", ["#batch"], [message],
               required_cap: "batch"
             )

    assert_receive {:ircxd, {:batch_start, %{ref: "b1", type: "draft/example"}}}, 2_000

    assert_receive {:ircxd, {:privmsg, %{target: "#batch", body: "inside batch", batch: "b1"}}},
                   2_000

    assert_receive {:ircxd, {:batch_end, %{ref: "b1"}}}, 2_000
  end

  defp start_client(server, nick, caps, notify) do
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

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
