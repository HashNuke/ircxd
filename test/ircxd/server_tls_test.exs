defmodule Ircxd.ServerTlsTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  @certfile Path.expand("../support/tls/server.crt", __DIR__)
  @keyfile Path.expand("../support/tls/server.key", __DIR__)
  @cacertfile Path.expand("../support/tls/ca.crt", __DIR__)

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
        tls_options: [cacertfile: @cacertfile],
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

  test "rejects a TLS server whose certificate is not trusted" do
    {:ok, server} = start_tls_server()
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, client} =
      GenServer.start(
        Client,
        client_options(Server.port(server), "untrusted-client", [])
      )

    ref = Process.monitor(client)
    assert_receive {:ircxd, {:connect_error, _reason}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^client, _reason}, 5_000
  end

  test "rejects a trusted certificate for the wrong hostname" do
    {:ok, server} = start_tls_server()
    on_exit(fn -> stop_if_alive(server) end)

    options =
      Server.port(server)
      |> client_options("hostname-client", cacertfile: @cacertfile)
      |> Keyword.put(:host, "127.0.0.1")

    {:ok, client} = GenServer.start(Client, options)
    ref = Process.monitor(client)

    assert_receive {:ircxd, {:connect_error, _reason}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^client, _reason}, 5_000
  end

  test "a stalled TLS handshake does not block later clients" do
    {:ok, server} = start_tls_server(handshake_timeout: 250, max_handshakes: 2)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, stalled_socket} =
      :gen_tcp.connect(~c"localhost", Server.port(server), [:binary, active: false], 2_000)

    on_exit(fn -> :gen_tcp.close(stalled_socket) end)

    {:ok, client} =
      Client.start_link(
        client_options(
          Server.port(server),
          "concurrent-client",
          cacertfile: @cacertfile
        )
      )

    on_exit(fn -> stop_if_alive(client) end)
    assert_receive {:ircxd, :registered}, 5_000
  end

  defp start_tls_server(extra_options \\ []) do
    Server.start_link(
      Keyword.merge(
        [port: 0, tls: true, tls_options: [certfile: @certfile, keyfile: @keyfile]],
        extra_options
      )
    )
  end

  defp client_options(port, nick, tls_options) do
    [
      host: "localhost",
      port: port,
      tls: true,
      tls_options: tls_options,
      nick: nick,
      username: nick,
      realname: nick,
      notify: self()
    ]
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
