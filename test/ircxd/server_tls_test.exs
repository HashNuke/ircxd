defmodule Ircxd.ServerTlsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  @certfile Path.expand("../support/tls/server.crt", __DIR__)
  @keyfile Path.expand("../support/tls/server.key", __DIR__)

  test "accepts Ircxd.Client connections over implicit TLS" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        tls: true,
        tls_options: [certfile: @certfile, keyfile: @keyfile]
      )

    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      Client.start_link(
        host: "localhost",
        port: Server.port(server),
        tls: true,
        tls_options: [verify: :verify_none],
        nick: "tls-client",
        username: "tls-client",
        realname: "Ircxd TLS client",
        notify: self()
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 5_000

    assert :ok = Client.raw(client, "PING", ["tls-check"])
    assert_receive {:ircxd, {:pong, %{token: "tls-check"}}}, 2_000
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
