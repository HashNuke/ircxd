defmodule Ircxd.ServerValidationTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "rejects JOIN targets that are not channel names" do
    {:ok, server} = Server.start_link(port: 0, server_name: "ircxd.test")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: Server.port(server),
        nick: "validation-client",
        username: "validation-client",
        realname: "Ircxd validation client",
        notify: self()
      )

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    wait_registered()

    assert :ok = Client.join(client, "not-a-channel")

    assert_receive {:ircxd,
                    {:irc_error,
                     %{code: "403", target: "not-a-channel", reason: "No such channel"}}},
                   2_000
  end

  defp wait_registered do
    receive do
      {:ircxd, :registered} -> :ok
      _other -> wait_registered()
    after
      2_000 -> flunk("client did not register")
    end
  end
end
