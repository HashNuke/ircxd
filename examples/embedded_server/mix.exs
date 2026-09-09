defmodule EmbeddedServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :embedded_server,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EmbeddedServer.Application, []}
    ]
  end

  defp deps do
    [
      {:ircxd, path: "../.."}
    ]
  end
end
