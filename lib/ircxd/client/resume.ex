defmodule Ircxd.Client.Resume do
  @moduledoc """
  Versioned, bounded, credential-free parser checkpoint for an already registered client.

  Checkpoints contain only state mutated while accepting inbound records. Outbound command
  correlation remains process-local because command parameters may contain credentials. Deferred
  server-time events and state larger than the fixed envelope are explicitly non-resumable.
  """

  alias Ircxd.{CTCP, DCC, Message, Source}

  @safe_structs [CTCP, DCC, Source]

  @version 1
  @max_checkpoint_bytes 65_536
  @state_fields [
    :current_nick,
    :available_caps,
    :active_caps,
    :isupport,
    :seen_msgids,
    :active_batches,
    :cap_list_buffer,
    :multiline_batches,
    :labeled_response_batches,
    :isupport_batches,
    :metadata_batches,
    :net_batches
  ]

  @typedoc "Opaque parser checkpoint retained by a transport owner."
  @type t :: %{
          version: pos_integer(),
          binding: map(),
          payload: binary(),
          digest: binary()
        }

  @type unavailable_reason ::
          :checkpoint_too_large | :deferred_server_time | :invalid_parser_state

  @doc false
  @spec checkpoint(map()) :: t() | nil | {:unavailable, unavailable_reason()}
  def checkpoint(%{registered?: true, server_time_buffer: [_entry | _rest]}),
    do: {:unavailable, :deferred_server_time}

  def checkpoint(%{registered?: true} = state) do
    snapshot = Map.take(state, @state_fields)

    cond do
      not valid_payload?(snapshot) ->
        {:unavailable, :invalid_parser_state}

      :erlang.external_size(snapshot) > @max_checkpoint_bytes ->
        {:unavailable, :checkpoint_too_large}

      true ->
        payload = :erlang.term_to_binary(snapshot)

        checkpoint = %{
          version: @version,
          binding: config_binding(state),
          payload: payload,
          digest: :crypto.hash(:sha256, payload)
        }

        if :erlang.external_size(checkpoint) <= @max_checkpoint_bytes do
          checkpoint
        else
          {:unavailable, :checkpoint_too_large}
        end
    end
  end

  def checkpoint(_state), do: nil

  @doc false
  @spec restore(term(), map()) :: {:ok, map()} | {:error, term()}
  def restore(
        %{
          version: @version,
          binding: checkpoint_binding,
          payload: payload,
          digest: digest
        } = checkpoint,
        state
      )
      when is_map(checkpoint_binding) and is_binary(payload) and is_binary(digest) do
    with :ok <- validate_envelope(checkpoint, payload, digest),
         :ok <- validate_binding(checkpoint_binding, state),
         {:ok, restored} <- decode_payload(payload),
         :ok <- validate_payload(restored) do
      {:ok,
       state
       |> Map.merge(restored)
       |> Map.merge(%{
         registered?: true,
         reconnect_attempts: 0,
         server_time_flush_timer: nil
       })}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def restore(%{version: version}, _state) when is_integer(version),
    do: {:error, :unsupported_resume_version}

  def restore(_checkpoint, _state), do: {:error, :invalid_resume_checkpoint}

  defp validate_envelope(checkpoint, payload, digest) do
    expected_keys = MapSet.new([:version, :binding, :payload, :digest])

    if Map.keys(checkpoint) |> MapSet.new() |> MapSet.equal?(expected_keys) and
         byte_size(digest) == 32 and byte_size(payload) <= @max_checkpoint_bytes and
         :erlang.external_size(checkpoint) <= @max_checkpoint_bytes and
         uncompressed_map_term?(payload) and :crypto.hash(:sha256, payload) == digest do
      :ok
    else
      {:error, :invalid_resume_checkpoint}
    end
  end

  defp decode_payload(payload) do
    case :erlang.binary_to_term(payload, [:safe, :used]) do
      {term, used} when used == byte_size(payload) -> {:ok, term}
      _term_with_trailing_data -> {:error, :invalid_resume_checkpoint}
    end
  rescue
    ArgumentError -> {:error, :invalid_resume_checkpoint}
  end

  defp validate_binding(checkpoint_binding, state) do
    checkpoint_binding = Map.put_new(checkpoint_binding, :additional_error_numerics, [])

    if checkpoint_binding == config_binding(state),
      do: :ok,
      else: {:error, :resume_binding_mismatch}
  end

  defp validate_payload(payload) do
    if valid_payload?(payload),
      do: :ok,
      else: {:error, :invalid_resume_checkpoint}
  end

  defp valid_payload?(restored) when is_map(restored) do
    valid_keys? = Map.keys(restored) |> MapSet.new() |> MapSet.equal?(MapSet.new(@state_fields))

    valid_keys? and nonempty_binary?(restored.current_nick) and
      caps?(restored.available_caps) and string_set?(restored.active_caps) and
      isupport?(restored.isupport) and string_set?(restored.seen_msgids) and
      parser_map?(restored.active_batches) and caps?(restored.cap_list_buffer) and
      parser_map?(restored.multiline_batches) and
      parser_map?(restored.labeled_response_batches) and
      parser_map?(restored.isupport_batches) and parser_map?(restored.metadata_batches) and
      parser_map?(restored.net_batches)
  end

  defp valid_payload?(_restored), do: false

  defp caps?(caps) when is_map(caps) do
    Enum.all?(caps, fn
      {name, true} when is_binary(name) and byte_size(name) > 0 -> true
      {name, value} when is_binary(name) and byte_size(name) > 0 and is_binary(value) -> true
      _invalid -> false
    end)
  end

  defp caps?(_caps), do: false

  defp isupport?(isupport) when is_map(isupport) do
    Enum.all?(isupport, fn
      {name, value}
      when is_binary(name) and byte_size(name) > 0 and
             (is_boolean(value) or is_binary(value)) ->
        true

      _invalid ->
        false
    end)
  end

  defp isupport?(_isupport), do: false

  defp string_set?(%MapSet{} = set), do: Enum.all?(set, &is_binary/1)
  defp string_set?(_set), do: false

  defp parser_map?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and is_map(value) and safe_term?(value) end)
  end

  defp parser_map?(_map), do: false

  defp safe_term?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: true

  defp safe_term?(%Message{} = message) do
    is_map(message.tags) and
      Enum.all?(message.tags, fn
        {key, value} when is_binary(key) and (is_binary(value) or value == true) -> true
        _invalid -> false
      end) and
      (is_nil(message.source) or is_binary(message.source)) and is_binary(message.command) and
      Enum.all?(message.params, &is_binary/1)
  end

  defp safe_term?(%DateTime{}), do: true
  defp safe_term?(%MapSet{} = set), do: Enum.all?(set, &safe_term?/1)

  defp safe_term?(%{__struct__: module} = struct) when module in @safe_structs,
    do: struct |> Map.from_struct() |> safe_term?()

  defp safe_term?(value) when is_struct(value), do: false
  defp safe_term?(value) when is_list(value), do: Enum.all?(value, &safe_term?/1)

  defp safe_term?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&safe_term?/1)

  defp safe_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> safe_term?(key) and safe_term?(nested) end)
  end

  defp safe_term?(_value), do: false

  defp config_binding(state) do
    %{
      host: state.host,
      port: state.port,
      tls?: state.tls,
      sni: state.sni,
      tls_policy: tls_policy_binding(state),
      authentication: authentication_binding(state),
      resume_binding: fingerprint(Map.get(state, :resume_binding)),
      nick: state.nick,
      username: state.username,
      realname: state.realname,
      caps: state.caps |> Enum.map(&to_string/1) |> Enum.sort(),
      additional_error_numerics:
        state
        |> Map.get(:additional_error_numerics, MapSet.new())
        |> Enum.sort(),
      msgid_dedupe: state.msgid_dedupe,
      server_time_order: server_time_order_binding(state.server_time_order)
    }
  end

  defp tls_policy_binding(%{tls: false}), do: nil

  defp tls_policy_binding(state) do
    opts = state.tls_options

    %{
      verify: Keyword.get(opts, :verify, :verify_peer),
      depth: Keyword.get(opts, :depth),
      versions: opts |> Keyword.get(:versions, []) |> Enum.map(&to_string/1) |> Enum.sort(),
      server_name_indication: effective_sni(state, opts),
      cacerts: fingerprint(Keyword.get(opts, :cacerts)),
      cacertfile: path_option(opts, :cacertfile),
      certificate: fingerprint(Keyword.get(opts, :cert)),
      certfile: path_option(opts, :certfile),
      keyfile: path_option(opts, :keyfile),
      hostname_check: hostname_check_binding(opts),
      partial_chain: callback_identity(Keyword.get(opts, :partial_chain)),
      verify_fun: verify_fun_identity(Keyword.get(opts, :verify_fun)),
      crl_check: Keyword.get(opts, :crl_check),
      ciphers: fingerprint(Keyword.get(opts, :ciphers)),
      signature_algs: fingerprint(Keyword.get(opts, :signature_algs)),
      signature_algs_cert: fingerprint(Keyword.get(opts, :signature_algs_cert)),
      supported_groups: fingerprint(Keyword.get(opts, :supported_groups)),
      inline_key?: Keyword.has_key?(opts, :key),
      key_password?: Keyword.has_key?(opts, :password),
      bundled_credentials?: Keyword.has_key?(opts, :certs_keys),
      srp_identity?: Keyword.has_key?(opts, :srp_identity),
      user_lookup?: Keyword.has_key?(opts, :user_lookup_fun)
    }
  end

  defp path_option(opts, key) do
    case Keyword.get(opts, key) do
      path when is_binary(path) -> path
      path when is_list(path) -> List.to_string(path)
      _path -> nil
    end
  end

  defp effective_sni(state, opts) do
    case Keyword.get(opts, :server_name_indication, state.sni) do
      sni when is_binary(sni) -> sni
      sni when is_list(sni) -> normalize_sni_charlist(sni)
      sni when is_atom(sni) -> sni
      _sni -> :invalid
    end
  end

  defp normalize_sni_charlist(sni) do
    List.to_string(sni)
  rescue
    ArgumentError -> :invalid
  end

  defp hostname_check_binding(opts) do
    case Keyword.get(opts, :customize_hostname_check) do
      hostname_opts when is_list(hostname_opts) ->
        hostname_opts |> Keyword.get(:match_fun) |> callback_identity()

      _hostname_opts ->
        nil
    end
  end

  defp verify_fun_identity({callback, _private_state}), do: callback_identity(callback)
  defp verify_fun_identity(_verify_fun), do: nil

  defp callback_identity(callback) when is_function(callback),
    do: callback |> public_policy_term() |> fingerprint()

  defp callback_identity(_callback), do: nil

  defp authentication_binding(state) do
    %{
      server_password?: Map.get(state, :password) not in [nil, ""],
      sasl: sasl_identity(Map.get(state, :sasl)),
      webirc: webirc_identity(Map.get(state, :webirc))
    }
  end

  defp sasl_identity(nil), do: []

  defp sasl_identity(mechanisms) when is_list(mechanisms) do
    Enum.map(mechanisms, &sasl_mechanism_identity/1)
  end

  defp sasl_identity(mechanism), do: [sasl_mechanism_identity(mechanism)]

  defp sasl_mechanism_identity({:plain, account, _password}),
    do: %{mechanism: "PLAIN", account: account}

  defp sasl_mechanism_identity({:external, authzid}),
    do: %{mechanism: "EXTERNAL", authzid: authzid}

  defp sasl_mechanism_identity({:scram_sha_256, account, _password}),
    do: %{mechanism: "SCRAM-SHA-256", account: account}

  defp sasl_mechanism_identity({:scram_sha_256, account, _password, _opts}),
    do: %{mechanism: "SCRAM-SHA-256", account: account}

  defp sasl_mechanism_identity(other), do: %{unsupported: fingerprint(other)}

  defp webirc_identity(nil), do: nil

  defp webirc_identity(webirc) when is_list(webirc) or is_map(webirc) do
    %{
      gateway: config_value(webirc, :gateway),
      hostname: config_value(webirc, :hostname),
      ip: config_value(webirc, :ip),
      options: fingerprint(config_value(webirc, :options))
    }
  end

  defp webirc_identity(other), do: %{unsupported: fingerprint(other)}

  defp config_value(config, key) when is_list(config), do: Keyword.get(config, key)
  defp config_value(config, key) when is_map(config), do: Map.get(config, key)

  defp fingerprint(nil), do: nil

  defp fingerprint(value) do
    value
    |> public_policy_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp public_policy_term(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: value

  defp public_policy_term(value) when is_function(value) do
    for key <- [:module, :name, :arity, :type, :index, :new_uniq], into: %{} do
      {^key, detail} = :erlang.fun_info(value, key)
      {key, detail}
    end
  end

  defp public_policy_term(value) when is_list(value), do: Enum.map(value, &public_policy_term/1)

  defp public_policy_term(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&public_policy_term/1) |> List.to_tuple()
  end

  defp public_policy_term(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {public_policy_term(key), public_policy_term(nested)} end)
  end

  defp public_policy_term(_value), do: :unsupported

  defp server_time_order_binding(opts) when is_list(opts) do
    %{flush_after: Keyword.get(opts, :flush_after)}
  end

  defp server_time_order_binding(mode), do: mode

  defp uncompressed_map_term?(<<131, 116, _rest::binary>>), do: true
  defp uncompressed_map_term?(_payload), do: false

  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0
end
