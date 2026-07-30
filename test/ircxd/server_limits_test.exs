defmodule Ircxd.ServerLimitsTest do
  use ExUnit.Case, async: false

  alias Ircxd.Server

  test "returns 417 for an input line over the IRC wire limit" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", Server.port(server), [:binary, packet: :line, active: false])

    on_exit(fn -> :gen_tcp.close(socket) end)
    :ok = :gen_tcp.send(socket, String.duplicate("A", 600) <> "\r\n")

    assert {:ok, "417 * :Input line too long\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
