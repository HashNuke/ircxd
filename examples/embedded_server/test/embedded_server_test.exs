defmodule EmbeddedServerTest do
  use ExUnit.Case, async: false

  test "the application supervises a reachable IRC server" do
    server = Process.whereis(EmbeddedServer.IrcServer)

    assert is_pid(server)

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: Ircxd.Server.port(server),
        nick: "example-test",
        username: "example-test",
        realname: "Embedded server test",
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 2_000
    assert :ok = Ircxd.Client.join(client, "#example")
    assert_receive {:ircxd, {:join, %{nick: "example-test", channel: "#example"}}}, 2_000

    assert {:ok, [%{nick: "example-test"}]} = Ircxd.Server.query(server, :users)

    assert {:ok, [%{name: "#example", members: ["example-test"]}]} =
             Ircxd.Server.query(server, :channels)
  end
end
