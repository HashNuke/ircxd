defmodule Ircxd.RawIrcClient do
  @moduledoc false

  def connect(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    nick = Keyword.fetch!(opts, :nick)

    {:ok, socket} =
      :gen_tcp.connect(
        String.to_charlist(host),
        port,
        [:binary, packet: :line, active: false],
        5_000
      )

    send_line(socket, "NICK #{nick}")
    send_line(socket, "USER #{nick} 0 * :#{nick}")
    {:ok, _line, _seen} = wait_for(socket, " 001 ", 15_000)
    {:ok, socket}
  end

  def join(socket, channel) do
    send_line(socket, "JOIN #{channel}")
    wait_for(socket, " JOIN :#{channel}", 5_000)
  end

  def privmsg(socket, target, body), do: send_line(socket, "PRIVMSG #{target} :#{body}")
  def close(socket), do: :gen_tcp.close(socket)

  def send_line(socket, line), do: :gen_tcp.send(socket, [line, "\r\n"])

  def wait_for(socket, pattern, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_until(socket, pattern, deadline, [])
  end

  defp wait_for_until(socket, pattern, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.recv(socket, 0, remaining) do
      {:ok, line} ->
        line = String.trim(line)

        cond do
          String.starts_with?(line, "PING ") ->
            token = String.replace_prefix(line, "PING ", "")
            send_line(socket, "PONG #{token}")
            wait_for_until(socket, pattern, deadline, [line | acc])

          String.contains?(line, pattern) ->
            {:ok, line, Enum.reverse([line | acc])}

          true ->
            wait_for_until(socket, pattern, deadline, [line | acc])
        end

      {:error, :timeout} ->
        {:error, {:timeout, Enum.reverse(acc)}}

      {:error, reason} ->
        {:error, {reason, Enum.reverse(acc)}}
    end
  end
end
