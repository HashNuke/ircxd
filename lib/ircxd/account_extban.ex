defmodule Ircxd.AccountExtban do
  @moduledoc """
  Helpers for IRCv3 account extended-ban masks.
  """

  def mask(isupport, account, preferred_name \\ nil) when is_map(isupport) do
    with {:ok, prefix} <- extban_prefix(isupport),
         {:ok, name} <- account_extban_name(isupport, preferred_name) do
      {:ok, prefix <> name <> ":" <> account}
    end
  end

  defp extban_prefix(isupport) do
    case Ircxd.ISupport.extban(isupport) do
      %{prefix: prefix} -> {:ok, prefix}
      nil -> {:error, :account_extban_not_supported}
    end
  end

  defp account_extban_name(%{"ACCOUNTEXTBAN" => value}, preferred_name) when is_binary(value) do
    names = String.split(value, ",", trim: true)

    cond do
      preferred_name in names -> {:ok, preferred_name}
      names != [] -> {:ok, List.first(names)}
      true -> {:error, :account_extban_not_supported}
    end
  end

  defp account_extban_name(_isupport, _preferred_name),
    do: {:error, :account_extban_not_supported}
end
