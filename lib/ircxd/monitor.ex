defmodule Ircxd.Monitor do
  @moduledoc """
  Parser helpers for IRCv3 MONITOR replies.
  """

  alias Ircxd.Source

  @spec parse_targets(String.t()) :: [String.t()]
  def parse_targets(targets) when is_binary(targets) do
    String.split(targets, ",", trim: true)
  end

  @spec parse_numeric(String.t(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def parse_numeric("730", [_me, targets]) do
    targets = parse_targets(targets)

    {:ok,
     %{
       type: :online,
       targets: targets,
       sources: Enum.map(targets, &source_summary/1)
     }}
  end

  def parse_numeric("731", [_me, targets]) do
    {:ok, %{type: :offline, targets: parse_targets(targets)}}
  end

  def parse_numeric("732", [_me, targets]) do
    {:ok, %{type: :list, targets: parse_targets(targets)}}
  end

  def parse_numeric("733", [_me | _rest]) do
    {:ok, %{type: :list_end}}
  end

  def parse_numeric("734", [_me, limit, targets, description]) do
    {:ok,
     %{
       type: :list_full,
       limit: parse_int(limit),
       targets: parse_targets(targets),
       description: description
     }}
  end

  def parse_numeric(_command, _params), do: {:error, :unsupported_numeric}

  defp source_summary(target) do
    case Source.parse(target) do
      %Source{} = source ->
        %{nick: source.nick || source.server, user: source.user, host: source.host}

      nil ->
        %{nick: target, user: nil, host: nil}
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
