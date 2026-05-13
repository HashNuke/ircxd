defmodule Ircxd.ClientServicesIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :services_integration

  @host System.get_env("IRCXD_SERVICES_HOST", "127.0.0.1")
  @port String.to_integer(System.get_env("IRCXD_SERVICES_PORT", "6670"))

  setup_all do
    case :gen_tcp.connect(String.to_charlist(@host), @port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        flunk("""
        services integration server is not reachable at #{@host}:#{@port}: #{inspect(reason)}

        Start a local InspIRCd instance linked to Atheme services, then run:
          IRCXD_SERVICES_INTEGRATION=1 mix test --include services_integration
        """)
    end
  end

  test "authenticates against real services with SASL PLAIN" do
    account = unique_name("saslacct")
    password = unique_name("pass")

    {:ok, registrar} = start_client(account, caps: ["account-notify", "account-tag"])
    wait_event(:registered)
    register_account!(registrar, account, password)
    stop_client(registrar)

    {:ok, _client} =
      start_client("#{account}login",
        caps: ["sasl", "account-notify"],
        sasl: {:plain, account, password}
      )

    wait_event({:logged_in, %{account: account}})
    wait_event(:sasl_success)
    wait_event(:registered)
  end

  test "receives real account-tag and account-notify login and logout events" do
    sender = unique_name("acctsender")
    receiver = unique_name("acctrecv")
    password = unique_name("pass")

    {:ok, _receiver_client} = start_client(receiver, caps: ["account-tag"])
    wait_event(:registered)

    {:ok, sender_client} = start_client(sender, caps: ["account-notify", "account-tag"])
    wait_event(:registered)
    register_account!(sender_client, sender, password)

    assert :ok = Ircxd.Client.privmsg(sender_client, receiver, "hello with account tag")

    wait_event(
      {:privmsg,
       %{target: receiver, body: "hello with account tag", nick: sender, account: sender}}
    )

    assert :ok = Ircxd.Client.privmsg(sender_client, "NickServ", "LOGOUT")
    wait_event({:logged_out, %{}})
    wait_event({:account, %{nick: sender, account: nil, logged_in?: false}})
  end

  defp register_account!(client, account, password) do
    assert :ok =
             Ircxd.Client.privmsg(
               client,
               "NickServ",
               "REGISTER #{password} #{account}@example.test"
             )

    wait_event({:logged_in, %{account: account}})
    wait_event({:account, %{nick: account, account: account, logged_in?: true}})
  end

  defp start_client(nick, opts) do
    opts =
      [
        host: @host,
        port: @port,
        tls: false,
        nick: nick,
        username: nick,
        realname: nick,
        notify: self()
      ]
      |> Keyword.merge(opts)

    Ircxd.start_link(opts)
  end

  defp stop_client(client) do
    _ = Ircxd.Client.quit(client, "done")
    GenServer.stop(client, :normal, 1_000)
  catch
    :exit, _ -> :ok
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
          {:ok, value} -> {:ok, value}
          :cont -> receive_event(fun, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp match_event?(event, expected) when is_atom(expected), do: event == expected

  defp match_event?({name, payload}, {name, expected_payload}) when is_map(payload) do
    Enum.all?(expected_payload, fn {key, value} -> Map.get(payload, key) == value end)
  end

  defp match_event?(_, _), do: false
end
