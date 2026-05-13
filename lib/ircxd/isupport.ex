defmodule Ircxd.ISupport do
  @moduledoc """
  Parser for `RPL_ISUPPORT` (`005`) tokens.
  """

  @length_limit_keys ~w(AWAYLEN CHANNELLEN HOSTLEN KICKLEN NICKLEN TOPICLEN USERLEN)

  def parse_params(params) when is_list(params) do
    params
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "are supported by this server"))
    |> Map.new(&parse_token/1)
  end

  def parse_token("-" <> key), do: {key, false}

  def parse_token(token) do
    case String.split(token, "=", parts: 2) do
      [key, ""] -> {key, true}
      [key, value] -> {key, unescape_value(value)}
      [key] -> {key, true}
    end
  end

  def prefix_modes(isupport) when is_map(isupport) do
    case Map.get(isupport, "PREFIX", "(ov)@+") do
      value when value in [true, false] ->
        []

      "(" <> rest ->
        with [modes, prefixes] <- String.split(rest, ")", parts: 2),
             true <- String.length(modes) == String.length(prefixes) do
          modes
          |> String.graphemes()
          |> Enum.zip(String.graphemes(prefixes))
          |> Enum.map(fn {mode, prefix} -> %{mode: mode, prefix: prefix} end)
        else
          _ -> []
        end

      _value ->
        []
    end
  end

  def prefix_for_mode(isupport, mode)
      when is_map(isupport) and is_binary(mode) and byte_size(mode) == 1 do
    isupport
    |> prefix_modes()
    |> Enum.find_value(fn %{mode: prefix_mode, prefix: prefix} ->
      if prefix_mode == mode, do: prefix
    end)
  end

  def prefix_for_mode(_isupport, _mode), do: nil

  def mode_for_prefix(isupport, prefix)
      when is_map(isupport) and is_binary(prefix) and byte_size(prefix) == 1 do
    isupport
    |> prefix_modes()
    |> Enum.find_value(fn %{mode: mode, prefix: mode_prefix} ->
      if mode_prefix == prefix, do: mode
    end)
  end

  def mode_for_prefix(_isupport, _prefix), do: nil

  def chanmodes(isupport) when is_map(isupport) do
    parts =
      isupport
      |> Map.get("CHANMODES", "")
      |> string_value()
      |> String.split(",", trim: false)

    %{
      type_a: Enum.at(parts, 0, ""),
      type_b: Enum.at(parts, 1, ""),
      type_c: Enum.at(parts, 2, ""),
      type_d: Enum.at(parts, 3, ""),
      extra: Enum.drop(parts, 4)
    }
  end

  def channel_mode_type(isupport, mode)
      when is_map(isupport) and is_binary(mode) and byte_size(mode) == 1 do
    modes = chanmodes(isupport)

    cond do
      String.contains?(modes.type_a, mode) -> :list
      String.contains?(modes.type_b, mode) -> :always_arg
      String.contains?(modes.type_c, mode) -> :set_arg
      String.contains?(modes.type_d, mode) -> :never_arg
      true -> nil
    end
  end

  def channel_mode_type(_isupport, _mode), do: nil

  def chanlimit(isupport) when is_map(isupport) do
    isupport
    |> Map.get("CHANLIMIT", "")
    |> parse_pair_list()
    |> Enum.flat_map(fn {prefixes, limit} ->
      prefixes
      |> String.graphemes()
      |> Enum.map(&{&1, limit})
    end)
    |> Map.new()
  end

  def channel_limit(isupport, target) when is_map(isupport) and is_binary(target) do
    isupport
    |> chanlimit()
    |> Enum.find_value(fn {prefix, limit} ->
      if String.starts_with?(target, prefix), do: limit
    end)
  end

  def channel_limit(_isupport, _target), do: nil

  def maxlist(isupport) when is_map(isupport) do
    isupport
    |> Map.get("MAXLIST", "")
    |> parse_pair_list()
    |> Map.new()
  end

  def list_limit(isupport, mode)
      when is_map(isupport) and is_binary(mode) and byte_size(mode) == 1 do
    isupport
    |> maxlist()
    |> Enum.find_value(fn {modes, limit} ->
      if String.contains?(modes, mode), do: limit
    end)
  end

  def list_limit(_isupport, _mode), do: nil

  def targmax(isupport) when is_map(isupport) do
    isupport
    |> Map.get("TARGMAX", "")
    |> parse_pair_list()
    |> Map.new(fn {command, limit} -> {String.upcase(command), limit} end)
  end

  def max_targets(isupport) when is_map(isupport) do
    positive_integer(isupport, "MAXTARGETS")
  end

  def mode_limit(isupport) when is_map(isupport) do
    case Map.fetch(isupport, "MODES") do
      {:ok, true} -> :unlimited
      {:ok, value} -> parse_positive_integer_value(value)
      :error -> 3
    end
  end

  def silence_limit(isupport) when is_map(isupport) do
    case Map.fetch(isupport, "SILENCE") do
      {:ok, true} -> :unlimited
      {:ok, value} -> parse_positive_integer_value(value)
      :error -> nil
    end
  end

  def target_limit(isupport, command) when is_map(isupport) and is_binary(command) do
    normalized_command = String.upcase(command)

    isupport
    |> targmax()
    |> Map.get(normalized_command)
    |> case do
      nil -> legacy_target_limit(isupport, normalized_command)
      limit -> limit
    end
  end

  def target_limit(_isupport, _command), do: nil

  def target_allowed?(_isupport, _command, count) when not is_integer(count) or count < 0,
    do: false

  def target_allowed?(isupport, command, count) do
    case target_limit(isupport, command) do
      nil -> true
      :unlimited -> true
      limit when is_integer(limit) -> count <= limit
    end
  end

  def integer(isupport, key, default \\ nil) when is_map(isupport) and is_binary(key) do
    case Map.fetch(isupport, key) do
      {:ok, value} -> parse_integer_value(value, default)
      :error -> default
    end
  end

  def length_limit(isupport, key) when is_map(isupport) and is_binary(key) do
    normalized_key = String.upcase(key)

    if normalized_key in @length_limit_keys do
      positive_integer(isupport, normalized_key)
    end
  end

  def length_limit(_isupport, _key), do: nil

  defp positive_integer(isupport, key) do
    case Map.fetch(isupport, key) do
      {:ok, value} -> parse_positive_integer_value(value)
      :error -> nil
    end
  end

  defp legacy_target_limit(isupport, command) when command in ["PRIVMSG", "NOTICE"] do
    max_targets(isupport)
  end

  defp legacy_target_limit(_isupport, _command), do: nil

  def characters(isupport, key) when is_map(isupport) and is_binary(key) do
    isupport
    |> Map.get(key, "")
    |> string_value()
    |> String.graphemes()
  end

  def elist(isupport) when is_map(isupport) do
    isupport
    |> characters("ELIST")
    |> Enum.map(&String.downcase/1)
  end

  def list_extension?(isupport, extension)
      when is_map(isupport) and is_binary(extension) and byte_size(extension) == 1 do
    extension = String.downcase(extension)

    isupport
    |> elist()
    |> Enum.member?(extension)
  end

  def list_extension?(_isupport, _extension), do: false

  def exception_mode(isupport) when is_map(isupport) do
    mode_token(isupport, "EXCEPTS", "e")
  end

  def invite_exception_mode(isupport) when is_map(isupport) do
    mode_token(isupport, "INVEX", "I")
  end

  def extban(%{"EXTBAN" => value}) when is_binary(value) do
    case String.split(value, ",", parts: 2) do
      [prefix, types] when byte_size(prefix) <= 1 and types != "" ->
        if String.contains?(types, ",") do
          nil
        else
          %{prefix: prefix, types: String.graphemes(types)}
        end

      _invalid ->
        nil
    end
  end

  def extban(_isupport), do: nil

  def extban_type?(isupport, type)
      when is_map(isupport) and is_binary(type) and byte_size(type) == 1 do
    case extban(isupport) do
      %{types: types} -> Enum.member?(types, type)
      nil -> false
    end
  end

  def extban_type?(_isupport, _type), do: false

  def enabled?(isupport, key) when is_map(isupport) and is_binary(key) do
    case Map.fetch(isupport, key) do
      {:ok, false} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  def casemap(isupport) when is_map(isupport) do
    case Map.get(isupport, "CASEMAPPING") do
      value when is_binary(value) -> Ircxd.Casemapping.from_isupport(value)
      _value -> Ircxd.Casemapping.from_isupport(nil)
    end
  end

  def equal?(isupport, left, right) when is_map(isupport) do
    Ircxd.Casemapping.equal?(left, right, casemap(isupport))
  end

  def channel?(isupport, target) when is_map(isupport) and is_binary(target) do
    isupport
    |> channel_types()
    |> Enum.any?(&String.starts_with?(target, &1))
  end

  def channel?(_isupport, _target), do: false

  defp channel_types(%{"CHANTYPES" => value}) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.reject(&(&1 == ""))
  end

  defp channel_types(%{"CHANTYPES" => _value}), do: []
  defp channel_types(_isupport), do: ["#", "&"]

  def status_target?(isupport, target) when is_map(isupport) and is_binary(target) do
    isupport
    |> status_message_prefixes()
    |> Enum.any?(fn prefix ->
      String.starts_with?(target, prefix) and
        channel?(isupport, String.replace_prefix(target, prefix, ""))
    end)
  end

  def status_target?(_isupport, _target), do: false

  defp status_message_prefixes(%{"STATUSMSG" => value}) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.reject(&(&1 == ""))
  end

  defp status_message_prefixes(_isupport), do: []

  defp parse_pair_list(value) do
    value
    |> string_value()
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn item ->
      case String.split(item, ":", parts: 2) do
        [key, ""] when key != "" -> [{key, :unlimited}]
        [key, value] when key != "" -> parse_limit_pair(key, value)
        _ -> []
      end
    end)
  end

  defp parse_limit_pair(key, value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> [{key, limit}]
      _ -> []
    end
  end

  defp mode_token(isupport, key, default) do
    case Map.get(isupport, key) do
      true -> default
      value when is_binary(value) and byte_size(value) == 1 -> value
      _value -> nil
    end
  end

  defp parse_integer_value(value, default) do
    case Integer.parse(string_value(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end

  defp parse_positive_integer_value(value) do
    case Integer.parse(string_value(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: ""

  defp unescape_value(value) do
    Regex.replace(~r/\\x([0-9A-Fa-f]{2})/, value, fn _match, hex ->
      hex
      |> String.to_integer(16)
      |> List.wrap()
      |> List.to_string()
    end)
  end
end
