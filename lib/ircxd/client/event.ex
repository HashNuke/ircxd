defmodule Ircxd.Client.Event do
  @moduledoc """
  Canonical client event envelope and public event-name catalog.

  The legacy tuple or atom is retained in `:legacy`. `:derivative?` identifies
  alternate semantic or correlation views of content that may already have
  been emitted in another event.
  """

  alias Ircxd.Message
  alias Ircxd.Tags

  @terminal_names ~w(
    ack admin_email ban_list_end batch_end exception_list_end help_end info_end
    invite_exception_list_end invite_list_end isupport_batch links_end list_end metadata_batch
    labeled_response motd_end motd_missing names_end servlist_end stats_end trace_end users_disabled
    users_end who_end whois_end whowas_end ison time userhost version
  )a

  @derivative_names ~w(
    batched duplicate_msgid isupport_batch labeled_response message metadata_batch
    multiline netjoin netsplit reaction sts_policy sts_policy_error typing
  )a

  @names ~w(
    account account_registration ack admin_email admin_location admin_start away
    away_reply ban_list ban_list_end batch_end batch_error batch_start batched bounce
    cap_ack cap_del cap_list cap_ls cap_nak cap_new channel_created channel_mode
    channel_rename chathistory_error chathistory_target chghost connect_error connected
    disconnect disconnected duplicate_msgid error exception_list exception_list_end help
    help_end help_start info info_end invite invite_exception_list
    invite_exception_list_end invite_list invite_list_end inviting irc_error ison
    isupport isupport_batch join kick labeled_request labeled_response links links_end
    list_end list_entry list_start logged_in logged_out lusers message metadata
    metadata_batch metadata_error metadata_reply metadata_reply_error mode monitor
    monitor_error motd motd_end motd_missing motd_start multiline names names_end netjoin
    netsplit nick nick_in_use none notice now_away parse_error part pong privmsg quit raw
    reaction read_marker read_marker_error reconnect_exhausted reconnecting redact registered rehashing remote_isupport resumed
    sasl_failure sasl_mechanisms sasl_scram_error sasl_success server_created server_info
    servlist servlist_end setname standard_reply standard_reply_error starttls
    starttls_failed stats_command stats_end stats_line stats_linkinfo stats_uptime
    sts_policy sts_policy_error summoning tagmsg time topic topic_empty topic_reply
    topic_who_time trace trace_end try_again typing unaway user_mode userhost users
    users_disabled users_empty users_end users_start version wallops welcome who_end who_reply
    whois_account whois_actual_host whois_bot whois_certfp whois_channels whois_end
    whois_host whois_idle whois_modes whois_operator whois_registered_nick whois_secure
    whois_server whois_special whois_user whowas_end whowas_user whox_reply your_host
    youre_oper
  )a

  @enforce_keys [
    :name,
    :payload,
    :legacy,
    :message,
    :label,
    :batch,
    :server_time,
    :duplicate_msgid?,
    :origin,
    :terminal?,
    :derivative?
  ]
  defstruct @enforce_keys

  @type origin :: :message | :internal | :derivative
  @type legacy :: atom() | tuple()

  @type t :: %__MODULE__{
          name: atom(),
          payload: term(),
          legacy: legacy(),
          message: Message.t() | nil,
          label: String.t() | nil,
          batch: String.t() | nil,
          server_time: DateTime.t() | nil,
          duplicate_msgid?: boolean(),
          origin: origin(),
          terminal?: boolean(),
          derivative?: boolean()
        }

  @doc "Returns all public client event names."
  @spec names() :: [atom()]
  def names, do: @names

  @doc "Returns the event properties for a public event name."
  @spec spec(atom()) :: map() | nil
  def spec(name) when name in @names do
    %{
      name: name,
      terminal?: name in @terminal_names,
      derivative?: name in @derivative_names
    }
  end

  def spec(_name), do: nil

  @doc "Builds an event envelope from a legacy event."
  @spec from_legacy!(legacy(), Message.t() | nil) :: t()
  def from_legacy!(legacy, message_override \\ nil) do
    {name, payload} = split_legacy(legacy)

    unless name in @names do
      raise ArgumentError, "unregistered Ircxd.Client event: #{inspect(name)}"
    end

    message = message_override || message_from(name, payload)
    derivative? = name in @derivative_names

    %__MODULE__{
      name: name,
      payload: payload,
      legacy: legacy,
      message: message,
      label: metadata_value(payload, :label) || message_tag(message, &Tags.label/1),
      batch: batch_from(name, payload, message),
      server_time:
        datetime_metadata_value(payload, :server_time) || server_time_from_message(message),
      duplicate_msgid?: metadata_value(payload, :duplicate_msgid?) == true,
      origin: event_origin(message, derivative?),
      terminal?: name in @terminal_names,
      derivative?: derivative?
    }
  end

  defp split_legacy(name) when is_atom(name), do: {name, nil}
  defp split_legacy({name, payload}) when is_atom(name), do: {name, payload}

  defp split_legacy(event) when is_tuple(event) and tuple_size(event) > 2 do
    [name | values] = Tuple.to_list(event)
    {name, List.to_tuple(values)}
  end

  defp message_from(:message, %Message{} = message), do: message
  defp message_from(:raw, %Message{} = message), do: message

  defp message_from(_name, payload) when is_map(payload) do
    case Map.get(payload, :raw_message) || Map.get(payload, :message) do
      %Message{} = message -> message
      _ -> nil
    end
  end

  defp message_from(_name, _payload), do: nil

  defp metadata_value(payload, key) when is_map(payload), do: Map.get(payload, key)
  defp metadata_value(_payload, _key), do: nil

  defp binary_metadata_value(payload, key) do
    case metadata_value(payload, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp datetime_metadata_value(payload, key) do
    case metadata_value(payload, key) do
      %DateTime{} = value -> value
      _ -> nil
    end
  end

  defp batch_from(name, payload, message) do
    binary_metadata_value(payload, :batch) ||
      if(name in [:batch_start, :batch_end], do: binary_metadata_value(payload, :ref)) ||
      message_tag(message, &Tags.batch/1)
  end

  defp server_time_from_message(%Message{} = message) do
    case Tags.server_time(message) do
      {:ok, server_time} -> server_time
      _error -> nil
    end
  end

  defp server_time_from_message(_message), do: nil

  defp message_tag(%Message{} = message, fun), do: fun.(message)
  defp message_tag(_message, _fun), do: nil

  defp event_origin(_message, true), do: :derivative
  defp event_origin(%Message{}, false), do: :message
  defp event_origin(_message, false), do: :internal
end
