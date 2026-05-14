defmodule Ircxd.MixProject do
  use Mix.Project

  def project do
    [
      app: :ircxd,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp description do
    "IRC v2/Modern IRC and IRCv3 client library for Elixir applications."
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/completion_audit.md",
        "docs/spec_audit.md",
        "docs/stable_spec_matrix.md",
        "docs/ircv3_index_audit.md",
        "docs/modern_irc_audit.md",
        "docs/conformance_workflow.md",
        "docs/host_boundaries.md",
        "docs/embedding_events.md",
        "docs/dcc_boundaries.md",
        "docs/sts_boundaries.md",
        "docs/websocket_adapters.md",
        "docs/specs.md"
      ],
      groups_for_extras: [
        Audits: [
          "docs/completion_audit.md",
          "docs/spec_audit.md",
          "docs/stable_spec_matrix.md",
          "docs/ircv3_index_audit.md",
          "docs/modern_irc_audit.md",
          "docs/conformance_workflow.md"
        ],
        "Embedding Guides": [
          "docs/host_boundaries.md",
          "docs/embedding_events.md",
          "docs/dcc_boundaries.md",
          "docs/sts_boundaries.md",
          "docs/websocket_adapters.md"
        ],
        References: ["docs/specs.md"]
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "docs", "scripts", "mix.exs", "README.md", "LICENSE", ".formatter.exs"],
      licenses: ["MIT"],
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
