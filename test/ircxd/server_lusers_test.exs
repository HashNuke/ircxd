defmodule Ircxd.ServerLusersTest do
  use ExUnit.Case, async: false

  alias Ircxd.{Client, Server}

  test "reports live user and channel counts from LUSERS" do
    {:ok, server} = Server.start_link(port: 0)
    on_exit(fn -> stop_if_alive(server) end)

    {:ok, alice} = start_client(server, "lusers-alice")
    {:ok, bob} = start_client(server, "lusers-bob")

    on_exit(fn ->
      stop_if_alive(alice)
      stop_if_alive(bob)
    end)

    wait_registered(2)
    assert :ok = Client.join(alice, "#lusers")
    assert :ok = Client.join(bob, "#lusers")
    wait_for_joins(2)

    assert :ok = Client.lusers(alice)
    assert_receive {:ircxd, {:lusers, %{code: "251", text: text}}}, 2_000
    assert text =~ "2 users"
    assert_receive {:ircxd, {:lusers, %{code: "252", text: "operator(s) online"}}}, 2_000
    assert_receive {:ircxd, {:lusers, %{code: "253", text: "unknown connection(s)"}}}, 2_000
    assert_receive {:ircxd, {:lusers, %{code: "254", text: "channels formed"}}}, 2_000
    assert_receive {:ircxd, {:lusers, %{code: "255", text: text}}}, 2_000
    assert text =~ "2 clients"
  end

  defp start_client(server, nick) do
    Client.start_link(
      host: "127.0.0.1",
      port: Server.port(server),
      nick: nick,
      username: nick,
      realname: "Ircxd LUSERS client",
      notify: self()
    )
  end

  defp wait_registered(0), do: :ok

  defp wait_registered(remaining) do
    receive do
      {:ircxd, :registered} -> wait_registered(remaining - 1)
      _other -> wait_registered(remaining)
    after
      2_000 -> flunk("clients did not register")
    end
  end

  defp wait_for_joins(0), do: :ok

  defp wait_for_joins(remaining) do
    receive do
      {:ircxd, {:join, %{channel: "#lusers"}}} -> wait_for_joins(remaining - 1)
      _other -> wait_for_joins(remaining)
    after
      2_000 -> flunk("clients did not join")
    end
  end

  defp stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
