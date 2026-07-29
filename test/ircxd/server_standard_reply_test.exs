defmodule Ircxd.ServerStandardReplyTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "sends a standard FAIL alongside 421 for unknown commands" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "standard-reply-client",
        username: "standard-reply-client",
        realname: "Ircxd standard reply client",
        caps: ["standard-replies"],
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    wait_registered_and_capability()

    assert :ok = Client.raw(client, "BOGUS", [])

    assert_receive {:ircxd,
                    {:standard_reply,
                     %{
                       type: :fail,
                       command: "BOGUS",
                       code: "UNKNOWN_COMMAND",
                       description: "Unknown command"
                     }}},
                   2_000
  end

  defp wait_registered_and_capability do
    receive do
      {:ircxd, :registered} -> wait_registered_and_capability()
      {:ircxd, {:cap_ack, ["standard-replies"]}} -> :ok
      _other -> wait_registered_and_capability()
    after
      2_000 -> flunk("client did not register and negotiate standard-replies")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
