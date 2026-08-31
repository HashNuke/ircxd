defmodule Ircxd.ClientTransportAdapterTest do
  use ExUnit.Case, async: false

  alias Ircxd.Client.Info
  alias Ircxd.TestClientTransport

  test "an opt-in fresh transport uses the existing registration and acceptance flow" do
    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6667,
        nick: "keeper",
        username: "keeper-user",
        realname: "Keeper User",
        password: "server-secret",
        allow_insecure_auth: true,
        notify: self(),
        transport_adapter: {TestClientTransport, owner: self()}
      )

    assert_receive {:test_transport_connected, ^client, handle, config}

    assert config == %{
             host: "irc.example.test",
             port: 6667,
             sni: "irc.example.test",
             tls?: false
           }

    refute Map.has_key?(config, :password)
    assert_receive {:test_transport_sent, ^handle, "PASS server-secret\r\n"}
    assert_receive {:test_transport_sent, ^handle, "CAP LS 302\r\n"}
    assert_receive {:test_transport_sent, ^handle, "NICK keeper\r\n"}
    assert_receive {:test_transport_sent, ^handle, "USER keeper-user 0 * :Keeper User\r\n"}
    assert_receive {:ircxd, {:connected, %{host: "irc.example.test", port: 6667, tls: false}}}

    receipt = make_ref()
    TestClientTransport.deliver(client, handle, receipt, ":irc.test 001 keeper :Welcome\r\n")

    assert_receive {:ircxd, :registered}
    assert_receive {:test_transport_accepted, ^handle, ^receipt, checkpoint}
    assert %{version: 1, binding: %{nick: "keeper"}, payload: payload} = checkpoint
    assert is_binary(payload)

    assert %Info{transport: TestClientTransport, registered?: true, current_nick: "keeper"} =
             Ircxd.Client.connection_info(client)
  end

  test "a resumed transport restores protocol state without registration writes" do
    checkpoint = registered_checkpoint()

    metadata = %{generation: "generation-1", gap?: false, replayed_records: 2}

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6697,
        tls: true,
        nick: "desired",
        notify: self(),
        transport_adapter:
          {TestClientTransport, owner: self(), mode: {:resumed, checkpoint, metadata}}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}
    assert_receive {:ircxd, {:connected, %{tls: true}}}
    assert_receive {:ircxd, {:resumed, ^metadata}}
    assert_receive {:ircxd, :registered}
    refute_receive {:test_transport_sent, ^handle, _registration_line}, 100

    assert %Info{
             status: :registered,
             connected?: true,
             registered?: true,
             transport: TestClientTransport,
             desired_nick: "desired",
             current_nick: "LiveNick",
             available_caps: %{"batch" => true, "server-time" => true},
             active_caps: active_caps,
             isupport: %{"CASEMAPPING" => "rfc1459", "CHANTYPES" => "#&"},
             casemapping: :rfc1459
           } = Ircxd.Client.connection_info(client)

    assert active_caps == MapSet.new(["batch", "server-time"])

    receipt = make_ref()

    TestClientTransport.deliver(
      client,
      handle,
      receipt,
      ":friend!user@host PRIVMSG LiveNick :after restart\r\n"
    )

    assert_receive {:ircxd,
                    {:privmsg, %{nick: "friend", target: "LiveNick", body: "after restart"}}}

    assert_receive {:test_transport_accepted, ^handle, ^receipt, next_checkpoint}
    assert next_checkpoint.version == 1

    assert :ok = Ircxd.Client.privmsg(client, "#elixir", "hello")
    assert_receive {:test_transport_sent, ^handle, "PRIVMSG #elixir hello\r\n"}
  end

  test "data and closure from a stale transport handle are ignored" do
    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        nick: "keeper",
        notify: self(),
        transport_adapter: {TestClientTransport, owner: self()}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}
    stale_handle = {TestClientTransport, make_ref(), self(), :ok, :ok}

    TestClientTransport.deliver(
      client,
      stale_handle,
      :stale_receipt,
      ":irc.test 001 keeper :stale\r\n"
    )

    TestClientTransport.close(client, stale_handle, :stale_close)

    refute_receive {:ircxd, :registered}, 100
    refute_receive {:test_transport_accepted, ^stale_handle, :stale_receipt, _checkpoint}, 100
    assert Process.alive?(client)
    assert Ircxd.Client.connection_info(client).connected?

    TestClientTransport.close(client, handle, :upstream_closed)
    assert_receive {:ircxd, :disconnected}

    assert_receive {:ircxd,
                    {:disconnect,
                     %{
                       reason: :upstream_closed,
                       intentional?: false,
                       reconnecting?: false
                     }}}
  end

  test "accepted follows parse errors so malformed records do not poison replay" do
    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        nick: "keeper",
        notify: self(),
        transport_adapter: {TestClientTransport, owner: self()}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}
    assert_receive {:test_transport_sent, ^handle, "CAP LS 302\r\n"}
    assert_receive {:test_transport_sent, ^handle, "NICK keeper\r\n"}
    assert_receive {:test_transport_sent, ^handle, "USER keeper 0 * keeper\r\n"}
    assert_receive {:test_transport_activated, ^handle}
    assert_receive {:ircxd, {:connected, _metadata}}

    receipt = make_ref()
    TestClientTransport.deliver(client, handle, receipt, "@invalid-tag-without-command\r\n")

    assert {:ircxd, {:parse_error, _reason, "@invalid-tag-without-command\r\n"}} = next_message()
    assert {:test_transport_accepted, ^handle, ^receipt, nil} = next_message()
  end

  test "a checkpoint resumes an in-progress multiline batch" do
    checkpoint = registered_checkpoint()
    metadata = %{generation: "generation-1"}

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6697,
        tls: true,
        nick: "desired",
        notify: self(),
        transport_adapter:
          {TestClientTransport, owner: self(), mode: {:resumed, checkpoint, metadata}}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}
    assert_receive {:ircxd, {:connected, _metadata}}
    assert_receive {:ircxd, {:resumed, ^metadata}}
    assert_receive {:ircxd, :registered}

    TestClientTransport.deliver(
      client,
      handle,
      :batch_start,
      ":irc.test BATCH +multi draft/multiline #elixir\r\n"
    )

    assert_receive {:test_transport_accepted, ^handle, :batch_start, batch_checkpoint}
    GenServer.stop(client)

    {:ok, resumed_client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6697,
        tls: true,
        nick: "desired",
        notify: self(),
        transport_adapter:
          {TestClientTransport,
           owner: self(), mode: {:resumed, batch_checkpoint, %{generation: "generation-1"}}}
      )

    assert_receive {:test_transport_connected, ^resumed_client, resumed_handle, _config}
    assert_receive {:ircxd, {:connected, _metadata}}
    assert_receive {:ircxd, {:resumed, _metadata}}
    assert_receive {:ircxd, :registered}

    TestClientTransport.deliver(
      resumed_client,
      resumed_handle,
      :batch_line,
      "@batch=multi :friend!user@host PRIVMSG #elixir :hello\r\n"
    )

    assert_receive {:test_transport_accepted, ^resumed_handle, :batch_line,
                    %{version: 1} = line_checkpoint}

    assert :erlang.external_size(line_checkpoint) <= 65_536

    TestClientTransport.deliver(
      resumed_client,
      resumed_handle,
      :batch_end,
      ":irc.test BATCH -multi\r\n"
    )

    assert_receive {:ircxd, {:multiline, %{body: "hello", ref: "multi", target: "#elixir"}}}
    assert_receive {:test_transport_accepted, ^resumed_handle, :batch_end, _checkpoint}
  end

  test "an incompatible checkpoint is rejected and its handle is released" do
    checkpoint = registered_checkpoint()
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6697,
        tls: true,
        nick: "changed",
        notify: self(),
        transport_adapter:
          {TestClientTransport,
           owner: self(), mode: {:resumed, checkpoint, %{generation: "generation-1"}}}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}

    assert_receive {:test_transport_released, ^handle,
                    {:connect_rejected, :resume_binding_mismatch}}

    assert_receive {:ircxd, {:connect_error, :resume_binding_mismatch}}
    assert_receive {:EXIT, ^client, :resume_binding_mismatch}
    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "an invalid connect result releases the adapter handle" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        nick: "keeper",
        notify: self(),
        transport_adapter: {TestClientTransport, owner: self(), mode: :invalid}
      )

    assert_receive {:test_transport_connected, ^client, handle, config}
    refute Map.has_key?(config, :tls_options)

    assert_receive {:test_transport_released, ^handle,
                    {:connect_rejected, :invalid_transport_result}}

    assert_receive {:ircxd, {:connect_error, :invalid_transport_result}}
    assert_receive {:EXIT, ^client, :invalid_transport_result}
    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "a cleanup failure prevents reconnect with a second transport" do
    checkpoint = registered_checkpoint()
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6697,
        tls: true,
        nick: "changed",
        reconnect: true,
        notify: self(),
        transport_adapter:
          {TestClientTransport,
           owner: self(),
           mode: {:resumed, checkpoint, %{generation: "generation-1"}},
           close_result: {:error, :still_attached}}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}

    assert_receive {:test_transport_released, ^handle,
                    {:connect_rejected, :resume_binding_mismatch}}

    assert_receive {:ircxd, {:connect_error, {:transport_close_failed, :still_attached}}}
    assert_receive {:EXIT, ^client, {:transport_close_failed, :still_attached}}
    refute_receive {:test_transport_connected, ^client, _next_handle, _config}, 100
    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "cleanup failure for an invalid mode also prevents reconnect" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        nick: "keeper",
        reconnect: true,
        notify: self(),
        transport_adapter:
          {TestClientTransport,
           owner: self(), mode: :invalid, close_result: {:error, :still_attached}}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}

    assert_receive {:test_transport_released, ^handle,
                    {:connect_rejected, :invalid_transport_result}}

    assert_receive {:ircxd, {:connect_error, {:transport_close_failed, :still_attached}}}
    assert_receive {:EXIT, ^client, {:transport_close_failed, :still_attached}}
    refute_receive {:test_transport_connected, ^client, _next_handle, _config}, 100
    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "a fresh registration write failure releases the handle before activation" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        nick: "keeper",
        notify: self(),
        transport_adapter:
          {TestClientTransport, owner: self(), send_result: {:error, :write_blocked}}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}
    assert_receive {:test_transport_sent, ^handle, "CAP LS 302\r\n"}
    assert_receive {:test_transport_released, ^handle, {:connect_rejected, :write_blocked}}
    refute_receive {:test_transport_activated, ^handle}, 100
    refute_receive {:ircxd, {:connected, _metadata}}, 100
    assert_receive {:ircxd, {:connect_error, :write_blocked}}
    assert_receive {:EXIT, ^client, :write_blocked}
    Process.flag(:trap_exit, previous_trap_exit)
  end

  defp registered_checkpoint do
    {:ok, client} =
      Ircxd.Client.start_link(
        host: "irc.example.test",
        port: 6697,
        tls: true,
        nick: "desired",
        notify: self(),
        transport_adapter: {TestClientTransport, owner: self()}
      )

    assert_receive {:test_transport_connected, ^client, handle, _config}

    TestClientTransport.deliver(
      client,
      handle,
      :cap_ack,
      ":irc.test CAP desired ACK :batch server-time\r\n"
    )

    assert_receive {:test_transport_accepted, ^handle, :cap_ack, nil}
    TestClientTransport.deliver(client, handle, :welcome, ":irc.test 001 LiveNick :Welcome\r\n")
    assert_receive {:test_transport_accepted, ^handle, :welcome, _checkpoint}

    TestClientTransport.deliver(
      client,
      handle,
      :cap_new,
      ":irc.test CAP LiveNick NEW :batch server-time\r\n"
    )

    assert_receive {:test_transport_accepted, ^handle, :cap_new, _checkpoint}

    TestClientTransport.deliver(
      client,
      handle,
      :isupport,
      ":irc.test 005 LiveNick CASEMAPPING=rfc1459 CHANTYPES=#&\r\n"
    )

    assert_receive {:test_transport_accepted, ^handle, :isupport, checkpoint}
    GenServer.stop(client)
    checkpoint
  end

  defp next_message do
    receive do
      message -> message
    after
      1_000 -> flunk("expected a message")
    end
  end
end
