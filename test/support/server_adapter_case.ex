defmodule Ircxd.ServerAdapterCase do
  @moduledoc false

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    quote do
      use ExUnit.Case, async: false

      alias Ircxd.Server

      setup do
        {:ok, server} =
          Server.start_link(
            id: {:adapter_contract, make_ref()},
            port: 0,
            adapter: unquote(adapter)
          )

        on_exit(fn ->
          try do
            GenServer.stop(server)
          catch
            :exit, _reason -> :ok
          end
        end)

        %{server: server}
      end

      test "adapter contract stores and queries managed channel state", %{server: server} do
        assert {:ok, _channel} =
                 Server.execute(
                   server,
                   {:put_channel, "#contract", %{description: "Contract channel", topic: "Topic"}}
                 )

        assert {:ok, :ok} =
                 Server.execute(
                   server,
                   {:put_channel_roles, "#contract", "contract-account", [:owner]}
                 )

        assert {:ok, channel} = Server.query(server, {:channel, "#contract"})
        assert channel.name == "#contract"
        assert channel.description == "Contract channel"
        assert channel.topic == "Topic"
        assert channel.acl["contract-account"] == MapSet.new([:owner])
      end

      test "adapter contract isolates server instances", %{server: first} do
        {:ok, second} =
          Server.start_link(
            id: {:adapter_contract, make_ref()},
            port: 0,
            adapter: unquote(adapter)
          )

        on_exit(fn ->
          try do
            GenServer.stop(second)
          catch
            :exit, _reason -> :ok
          end
        end)

        assert {:ok, _channel} =
                 Server.execute(first, {:put_channel, "#isolated", %{topic: "First only"}})

        assert {:ok, %{topic: "First only"}} = Server.query(first, {:channel, "#isolated"})
        assert {:error, :not_found} = Server.query(second, {:channel, "#isolated"})
      end
    end
  end
end
