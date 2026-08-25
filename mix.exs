defmodule Ircxd.MixProject do
  use Mix.Project

  def project do
    [
      app: :ircxd,
      version: "1.0.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      test_coverage: [summary: [threshold: 85]],
      deps: deps(),
      description: description(),
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Ircxd.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [cover: :test]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      cover: "test --cover",
      bench: "run bench/ircxd.exs"
    ]
  end

  defp description do
    "IRC client library and embeddable IRC server for Elixir applications, with Modern IRC and IRCv3 support."
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/client-adapters.md",
        "docs/development.md",
        "docs/security.md",
        "docs/server-adapters.md"
      ],
      groups_for_extras: [
        Guides: [
          "docs/client-adapters.md",
          "docs/development.md",
          "docs/server-adapters.md"
        ],
        Security: ["docs/security.md"]
      ]
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "docs",
        "scripts",
        "mix.exs",
        "README.md",
        "LICENSE",
        ".formatter.exs"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "Repository" => "https://github.com/HashNuke/ircxd",
        "Modern IRC" => "https://modern.ircdocs.horse/",
        "IRCv3" => "https://ircv3.net/irc/"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
