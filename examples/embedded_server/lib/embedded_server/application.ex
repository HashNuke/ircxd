defmodule EmbeddedServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    server_options = Application.fetch_env!(:embedded_server, :irc_server)

    children = [
      {Ircxd.Server,
       Keyword.merge(
         [
           id: :embedded_irc,
           name: EmbeddedServer.IrcServer,
           adapter: {Ircxd.Server.Adapters.ETS, history_limit: 1_000}
         ],
         server_options
       )}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: EmbeddedServer.Supervisor
    )
  end
end
