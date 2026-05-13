defmodule Ircxd.ClientStandardRepliesIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :standard_replies_integration

  @host System.get_env("IRCXD_STANDARD_REPLIES_HOST", "127.0.0.1")
  @port String.to_integer(System.get_env("IRCXD_STANDARD_REPLIES_PORT", "6672"))

  setup_all do
    case :gen_tcp.connect(String.to_charlist(@host), @port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        flunk("""
        standard-replies integration server is not reachable at #{@host}:#{@port}: #{inspect(reason)}

        Start the disposable InspIRCd fixture, then run:
          scripts/run_standard_replies_integration.sh
        """)
    end
  end

  test "receives real FAIL standard replies from InspIRCd" do
    nick = unique_name("stdreply")

    {:ok, client} =
      Ircxd.start_link(
        host: @host,
        port: @port,
        tls: false,
        nick: nick,
        username: nick,
        realname: "standard replies test",
        caps: ["standard-replies", "setname"],
        notify: self()
      )

    wait_event(:registered)

    assert :ok = Ircxd.Client.setname(client, String.duplicate("x", 450))

    assert {:standard_reply,
            %{
              type: :fail,
              command: "SETNAME",
              code: "INVALID_REALNAME",
              context: [],
              description: "Real name is too long"
            }} = wait_event({:standard_reply, %{}})
  end

  defp unique_name(prefix) do
    "#{prefix}#{System.unique_integer([:positive])}"
  end

  defp wait_event(expected, timeout \\ 15_000) do
    assert {:ok, event} =
             receive_event(
               fn event ->
                 if match_event?(event, expected), do: {:ok, event}, else: :cont
               end,
               timeout
             )

    event
  end

  defp receive_event(fun, timeout) do
    receive do
      {:ircxd, event} ->
        case fun.(event) do
          {:ok, _} = ok -> ok
          :cont -> receive_event(fun, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp match_event?(event, expected) when is_atom(expected), do: event == expected

  defp match_event?({name, payload}, {name, expected_payload}) when is_map(expected_payload) do
    Enum.all?(expected_payload, fn {key, value} -> Map.get(payload, key) == value end)
  end

  defp match_event?(_event, _expected), do: false
end
