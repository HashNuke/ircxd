defmodule Ircxd.ClientCommand do
  @moduledoc """
  Parses and validates a client-to-server IRC command line.

  Unlike `Ircxd.Message.parse/1`, the default contract rejects server source
  prefixes, numeric replies, and message tags. Callers may opt into those
  grammar features explicitly, while connection-dependent capability and
  transport-security checks remain the responsibility of `Ircxd.Client`.
  """

  alias Ircxd.Message

  @typedoc "A grammar feature policy."
  @type option ::
          {:tags, :allow | :forbid}
          | {:source, :allow | :forbid}
          | {:numerics, :allow | :forbid}

  @doc """
  Parses and validates one client command line.

  Use `:tags`, `:source`, or `:numerics` with `:allow` to permit that grammar
  feature. Each option defaults to `:forbid`.
  """
  @spec parse(String.t(), [option()]) :: {:ok, Message.t()} | {:error, atom()}
  def parse(line, opts \\ [])

  def parse(line, opts) when is_binary(line) do
    with :ok <- validate_input_controls(line),
         {:ok, message} <- Message.parse(line),
         :ok <- validate(message, opts) do
      {:ok, message}
    end
  end

  def parse(_line, _opts), do: {:error, :invalid_line}

  @doc "Validates a client message with the same options as `parse/2`."
  @spec validate(Message.t(), [option()]) :: :ok | {:error, atom()}
  def validate(message, opts \\ [])

  def validate(%Message{} = message, opts) do
    with :ok <- validate_option(opts, :tags),
         :ok <- validate_option(opts, :source),
         :ok <- validate_option(opts, :numerics),
         :ok <- validate_command(message.command),
         :ok <- validate_source(message.source, Keyword.get(opts, :source, :forbid)),
         :ok <- validate_numeric(message.command, Keyword.get(opts, :numerics, :forbid)),
         :ok <- validate_params(message.params),
         :ok <- validate_tags(message.tags, Keyword.get(opts, :tags, :forbid)) do
      validate_wire_size(message)
    end
  end

  def validate(_message, _opts), do: {:error, :invalid_message}

  @doc "Converts the message command to uppercase."
  @spec normalize(Message.t()) :: Message.t()
  def normalize(%Message{command: command} = message) when is_binary(command),
    do: %{message | command: String.upcase(command)}

  def normalize(%Message{} = message), do: message

  defp validate_input_controls(line) do
    cond do
      String.contains?(line, <<0>>) -> {:error, :nul_not_allowed}
      String.contains?(line, ["\r", "\n"]) -> {:error, :line_break_not_allowed}
      true -> :ok
    end
  end

  defp validate_option(opts, key) do
    if Keyword.get(opts, key, :forbid) in [:allow, :forbid],
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp validate_command(command) when is_binary(command) do
    if Message.valid_command?(command), do: :ok, else: {:error, :invalid_command}
  end

  defp validate_command(_command), do: {:error, :invalid_command}

  defp validate_source(nil, _policy), do: :ok

  defp validate_source(source, :allow) when is_binary(source) do
    if source != "" and not String.contains?(source, [<<0>>, "\r", "\n", " ", ":"]),
      do: :ok,
      else: {:error, :invalid_source}
  end

  defp validate_source(_source, :allow), do: {:error, :invalid_source}
  defp validate_source(_source, :forbid), do: {:error, :source_not_allowed}

  defp validate_numeric(command, :forbid) do
    if String.match?(command, ~r/\A\d{3}\z/),
      do: {:error, :numeric_command_not_allowed},
      else: :ok
  end

  defp validate_numeric(_command, :allow), do: :ok

  defp validate_params(params) when is_list(params) do
    cond do
      length(params) > Message.max_params() ->
        {:error, :too_many_params}

      Enum.any?(params, &(not is_binary(&1))) ->
        {:error, :invalid_param}

      Enum.any?(params, &String.contains?(&1, [<<0>>, "\r", "\n"])) ->
        {:error, :invalid_param}

      params |> Enum.drop(-1) |> Enum.any?(&invalid_middle_param?/1) ->
        {:error, :invalid_param}

      true ->
        :ok
    end
  end

  defp validate_params(_params), do: {:error, :invalid_param}

  defp invalid_middle_param?(param) do
    param == "" or String.starts_with?(param, ":") or String.contains?(param, " ")
  end

  defp validate_tags(tags, :forbid) when tags == %{}, do: :ok
  defp validate_tags(tags, :forbid) when is_map(tags), do: {:error, :tags_not_allowed}

  defp validate_tags(tags, :allow) when is_map(tags) do
    with :ok <- validate_tag_keys(tags),
         :ok <- validate_tag_values(tags) do
      validate_label(tags)
    end
  end

  defp validate_tags(_tags, _policy), do: {:error, :invalid_tags}

  defp validate_tag_keys(tags) do
    if Enum.all?(Map.keys(tags), &valid_tag_key?/1),
      do: :ok,
      else: {:error, :invalid_tag_key}
  end

  defp valid_tag_key?(key) when is_binary(key) do
    String.match?(key, ~r/\A\+?(?:(?:[A-Za-z0-9][A-Za-z0-9.-]*)\/)?[A-Za-z0-9][A-Za-z0-9-]*\z/)
  end

  defp valid_tag_key?(_key), do: false

  defp validate_tag_values(tags) do
    if Enum.all?(Map.values(tags), &valid_tag_value?/1),
      do: :ok,
      else: {:error, :invalid_tag_value}
  end

  defp valid_tag_value?(true), do: true

  defp valid_tag_value?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  defp valid_tag_value?(_value), do: false

  defp validate_label(%{"label" => label})
       when is_binary(label) and byte_size(label) in 1..64,
       do: :ok

  defp validate_label(%{"label" => _label}), do: {:error, :invalid_label}
  defp validate_label(_tags), do: :ok

  defp validate_wire_size(message) do
    if message |> Message.serialize() |> Message.valid_wire_size?(),
      do: :ok,
      else: {:error, :line_too_long}
  end
end
