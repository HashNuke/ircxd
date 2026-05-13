defmodule Ircxd.StandardReply do
  @moduledoc """
  Parser helpers for IRCv3 standard replies.
  """

  @types %{"FAIL" => :fail, "WARN" => :warn, "NOTE" => :note}

  @spec parse(String.t(), [String.t()]) ::
          {:ok,
           %{
             type: :fail | :warn | :note,
             command: String.t(),
             code: String.t(),
             context: [String.t()],
             description: String.t()
           }}
          | {:error, atom()}
  def parse(type, [command, code, description]) do
    parse(type, [command, code], description)
  end

  def parse(type, [command, code | context_and_description]) do
    {description, context} = List.pop_at(context_and_description, -1)
    parse(type, [command, code | context], description)
  end

  def parse(type, _params) when is_binary(type) do
    case Map.fetch(@types, String.upcase(type)) do
      {:ok, _type} -> {:error, :missing_description}
      :error -> {:error, :invalid_type}
    end
  end

  defp parse(type, [command, code | context], description) do
    with {:ok, type} <- fetch_type(type),
         true <- is_binary(description) do
      {:ok,
       %{
         type: type,
         command: normalize_command(command),
         code: String.upcase(code),
         context: context,
         description: description
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_description}
    end
  end

  defp fetch_type(type) do
    case Map.fetch(@types, String.upcase(type)) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :invalid_type}
    end
  end

  defp normalize_command("*"), do: "*"
  defp normalize_command(command), do: String.upcase(command)
end
