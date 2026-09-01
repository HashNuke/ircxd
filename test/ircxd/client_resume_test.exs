defmodule Ircxd.ClientResumeTest do
  use ExUnit.Case, async: true

  alias Ircxd.Client.Resume

  test "round trips bounded inbound parser state without registration or command secrets" do
    state = resume_state()
    checkpoint = Resume.checkpoint(state)

    assert %{version: 1, binding: %{host: "irc.example.test", nick: "desired"}, payload: payload} =
             checkpoint

    assert <<131, 116, _rest::binary>> = payload
    assert :erlang.external_size(checkpoint) <= 65_536
    assert :binary.match(payload, "super-secret") == :nomatch

    encoded_checkpoint = :erlang.term_to_binary(checkpoint)
    assert :binary.match(encoded_checkpoint, "server-secret") == :nomatch
    assert :binary.match(encoded_checkpoint, "sasl-secret") == :nomatch
    assert :binary.match(encoded_checkpoint, "webirc-secret") == :nomatch
    assert :binary.match(encoded_checkpoint, "deployment-generation-1") == :nomatch

    decoded = :erlang.binary_to_term(payload, [:safe])
    refute Map.has_key?(decoded, :password)
    refute Map.has_key?(decoded, :sasl)
    refute Map.has_key?(decoded, :webirc)
    assert decoded.active_batches == %{"batch" => %{type: "draft/multiline"}}
    refute Map.has_key?(decoded, :labeled_requests)
    refute Map.has_key?(decoded, :multiline_ref)

    assert {:ok, restored} = Resume.restore(checkpoint, %{state | current_nick: nil})

    for field <- resumable_fields() do
      assert Map.fetch!(restored, field) == Map.fetch!(state, field)
    end
  end

  test "rejects config mismatches, unknown versions, and malformed payloads" do
    state = resume_state()
    checkpoint = Resume.checkpoint(state)

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{state | nick: "changed"})

    assert {:error, :unsupported_resume_version} =
             Resume.restore(%{checkpoint | version: 2}, state)

    assert {:error, :invalid_resume_checkpoint} =
             Resume.restore(%{checkpoint | payload: checkpoint.payload <> "corrupt"}, state)

    malformed =
      checkpoint.payload
      |> :erlang.binary_to_term([:safe])
      |> Map.put(:active_batches, %{"batch" => "not-a-batch"})
      |> :erlang.term_to_binary()

    assert {:error, :invalid_resume_checkpoint} =
             Resume.restore(
               %{
                 checkpoint
                 | payload: malformed,
                   digest: :crypto.hash(:sha256, malformed)
               },
               state
             )

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{state | tls_options: [verify: :verify_none]})

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{
               state
               | tls_options: [
                   verify: :verify_peer,
                   server_name_indication: ~c"other.example.test"
                 ]
             })
  end

  test "binds checkpoints to selected vendor error numerics while accepting the old empty default" do
    state = resume_state()
    checkpoint = Resume.checkpoint(state)

    selected = %{state | additional_error_numerics: MapSet.new(["479", "480"])}

    assert {:error, :resume_binding_mismatch} = Resume.restore(checkpoint, selected)

    legacy_checkpoint = %{
      checkpoint
      | binding: Map.delete(checkpoint.binding, :additional_error_numerics)
    }

    assert {:ok, _restored} = Resume.restore(legacy_checkpoint, state)
    assert {:error, :resume_binding_mismatch} = Resume.restore(legacy_checkpoint, selected)
  end

  test "binds checkpoints to public authentication identity and caller generation" do
    state = resume_state()
    checkpoint = Resume.checkpoint(state)

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{state | sasl: {:plain, "other-account", "sasl-secret"}})

    changed_webirc =
      Keyword.merge(state.webirc,
        gateway: "other-gateway",
        password: "webirc-secret"
      )

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{state | webirc: changed_webirc})

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{state | resume_binding: "deployment-generation-2"})
  end

  test "binds checkpoints to inline CA material and hostname verification policy" do
    hostname_check = [match_fun: fn _reference, _presented -> true end]

    state = %{
      resume_state()
      | tls_options: [
          verify: :verify_peer,
          cacerts: [<<1, 2, 3>>],
          customize_hostname_check: hostname_check
        ]
    }

    checkpoint = Resume.checkpoint(state)

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{
               state
               | tls_options: [
                   verify: :verify_peer,
                   cacerts: [<<4, 5, 6>>],
                   customize_hostname_check: hostname_check
                 ]
             })

    other_hostname_check = [match_fun: fn _reference, _presented -> false end]

    assert {:error, :resume_binding_mismatch} =
             Resume.restore(checkpoint, %{
               state
               | tls_options: [
                   verify: :verify_peer,
                   cacerts: [<<1, 2, 3>>],
                   customize_hostname_check: other_hostname_check
                 ]
             })
  end

  test "excludes secret-bearing TLS option values from the binding" do
    state = %{
      resume_state()
      | tls_options: [
          verify: :verify_peer,
          certs_keys: [[cert: <<1, 2, 3>>, key: {:private, "nested-key-secret"}]],
          srp_identity: {"srp-user", "srp-password-secret"},
          user_lookup_fun: {fn _, _ -> :ok end, "lookup-state-secret"}
        ]
    }

    checkpoint = Resume.checkpoint(state)
    encoded_checkpoint = :erlang.term_to_binary(checkpoint)

    assert :binary.match(encoded_checkpoint, "nested-key-secret") == :nomatch
    assert :binary.match(encoded_checkpoint, "srp-password-secret") == :nomatch
    assert :binary.match(encoded_checkpoint, "lookup-state-secret") == :nomatch

    changed_secrets = %{
      state
      | tls_options: [
          verify: :verify_peer,
          certs_keys: [[cert: <<9, 9, 9>>, key: {:private, "other-key-secret"}]],
          srp_identity: {"srp-user", "other-srp-secret"},
          user_lookup_fun: {fn _, _ -> :error end, "other-lookup-state"}
        ]
    }

    assert {:ok, _restored} = Resume.restore(checkpoint, changed_secrets)
  end

  test "does not produce a resumable checkpoint before registration" do
    assert Resume.checkpoint(%{resume_state() | registered?: false}) == nil
  end

  test "marks oversized and deferred server-time state as non-resumable" do
    state = resume_state()
    oversized = %{state | seen_msgids: MapSet.new([String.duplicate("x", 70_000)])}
    deferred = %{state | server_time_buffer: [%{index: 0}]}

    assert Resume.checkpoint(oversized) == {:unavailable, :checkpoint_too_large}
    assert Resume.checkpoint(deferred) == {:unavailable, :deferred_server_time}
  end

  defp resume_state do
    %{
      host: "irc.example.test",
      port: 6697,
      tls: true,
      sni: "irc.example.test",
      tls_options: [verify: :verify_peer],
      nick: "desired",
      username: "user",
      realname: "Real Name",
      caps: ["batch", "server-time"],
      msgid_dedupe: :mark,
      server_time_order: [flush_after: 50],
      additional_error_numerics: MapSet.new(),
      password: "server-secret",
      sasl: {:plain, "account", "sasl-secret"},
      webirc: [
        password: "webirc-secret",
        gateway: "gateway",
        hostname: "user.example.test",
        ip: "192.0.2.1",
        options: [secure: true]
      ],
      resume_binding: "deployment-generation-1",
      registered?: true,
      reconnect_attempts: 4,
      server_time_flush_timer: make_ref(),
      current_nick: "LiveNick",
      available_caps: %{"batch" => true},
      active_caps: MapSet.new(["batch"]),
      isupport: %{"CASEMAPPING" => "rfc1459"},
      seen_msgids: MapSet.new(["msg-1"]),
      server_time_buffer: [],
      active_batches: %{"batch" => %{type: "draft/multiline"}},
      cap_list_buffer: %{"batch" => true},
      multiline_batches: %{"batch" => %{target: "#elixir", lines: []}},
      labeled_response_batches: %{"batch" => %{label: "label", events: []}},
      labeled_requests: %{"label" => %{command: "OPER", params: ["admin", "super-secret"]}},
      isupport_batches: %{"batch" => %{entries: []}},
      metadata_batches: %{"batch" => %{entries: []}},
      net_batches: %{"batch" => %{events: []}},
      multiline_ref: 7
    }
  end

  defp resumable_fields do
    ~w(
      current_nick available_caps active_caps isupport seen_msgids active_batches cap_list_buffer
      multiline_batches labeled_response_batches isupport_batches metadata_batches net_batches
    )a
  end
end
