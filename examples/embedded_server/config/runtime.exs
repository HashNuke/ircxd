import Config

default_port = if config_env() == :test, do: 0, else: 6667
port = System.get_env("IRC_PORT", Integer.to_string(default_port)) |> String.to_integer()

config :embedded_server, :irc_server,
  port: port,
  server_name: "irc.example.local",
  motd: ["This IRC server is supervised by EmbeddedServer"]
