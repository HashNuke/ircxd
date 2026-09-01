defmodule Ircxd.LegacyTestClientTransport do
  @moduledoc false

  @behaviour Ircxd.Client.Transport

  defdelegate connect(client, config, opts), to: Ircxd.TestClientTransport
  defdelegate send_data(handle, data), to: Ircxd.TestClientTransport
  defdelegate activate(handle), to: Ircxd.TestClientTransport
  defdelegate checkpoint?(handle), to: Ircxd.TestClientTransport
  defdelegate accepted(handle, receipt, checkpoint), to: Ircxd.TestClientTransport
  defdelegate handle_info(message, handle), to: Ircxd.TestClientTransport
  defdelegate close(handle, reason), to: Ircxd.TestClientTransport
end
