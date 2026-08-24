defmodule Ircxd.ConformanceDocsTest do
  use ExUnit.Case, async: true

  test "README points client and server integrators at their adapter guides" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    assert readme =~ "docs/client-adapters.md"
    assert readme =~ "docs/server-adapters.md"
    assert readme =~ "Ircxd.Client.Adapter"
    assert readme =~ "Ircxd.Server.Adapters.ETS"
  end

  test "README presents installation features and client/server command support" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    for heading <- [
          "## Features",
          "## Installation",
          "## Supported IRC commands",
          "### Client commands",
          "### Server commands"
        ] do
      assert readme =~ heading
    end

    assert readme =~ "`Ircxd.Client.raw/3`"
    assert readme =~ "adapter-defined commands"
    assert readme =~ "| Area | Commands |"
  end

  test "README keeps the embedded server quickstart concise" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    embedded_server_section =
      readme
      |> String.split("## Embedded IRC Server\n", parts: 2)
      |> List.last()
      |> String.split("\n## ", parts: 2)
      |> List.first()

    assert embedded_server_section |> String.split("\n") |> length() <= 70
  end

  test "README delegates testing and contributor setup to the development guide" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))
    guide = File.read!(Path.expand("../../docs/development.md", __DIR__))

    refute readme =~ "## Testing"
    refute readme =~ "## Development"
    assert readme =~ "[Development and testing](docs/development.md)"

    assert guide =~ "# Development"
    assert guide =~ "## Setup"
    assert guide =~ "## Testing"
    assert guide =~ "scripts/run_verification_gates.sh"
  end

  test "README local documentation references point to existing files" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))
    repo_root = Path.expand("../..", __DIR__)

    missing_paths =
      readme
      |> document_paths()
      |> Enum.reject(&File.exists?(Path.join(repo_root, &1)))

    assert [] = missing_paths
  end

  test "adapter guide documents the public integration contract" do
    guide = File.read!(Path.expand("../../docs/server-adapters.md", __DIR__))

    for required <- [
          "Ircxd.Server.Adapter",
          "Ircxd.Server.Adapters.ETS",
          "Ircxd.Server.Event",
          "Ircxd.Server.query/2",
          "Ircxd.Server.execute/2",
          "handle_event/3",
          "handle_query/3",
          "handle_operation/3",
          "authorize/3",
          "handle_command/3",
          "authenticate/4",
          "memory-only"
        ] do
      assert guide =~ required
    end
  end

  test "client adapter guide documents the matching public contract" do
    guide = File.read!(Path.expand("../../docs/client-adapters.md", __DIR__))

    for required <- [
          "Ircxd.Client.Adapter",
          "Ircxd.Server.Adapter",
          "adapter: {Module, init_arg}",
          "handle_event/3",
          "Ircxd.Handler",
          "docs/server-adapters.md"
        ] do
      assert guide =~ required
    end
  end

  test "all repository docs are included in generated ExDoc extras" do
    repo_root = Path.expand("../..", __DIR__)

    docs_files =
      repo_root
      |> Path.join("docs/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, repo_root))
      |> Enum.sort()

    configured_extras =
      Ircxd.MixProject.project()
      |> Keyword.fetch!(:docs)
      |> Keyword.fetch!(:extras)
      |> Enum.reject(&(&1 == "README.md"))
      |> Enum.sort()

    assert docs_files == configured_extras
  end

  test "package metadata includes source docs license and protocol links" do
    package = Ircxd.MixProject.project() |> Keyword.fetch!(:package)

    assert Keyword.fetch!(package, :files) == [
             "lib",
             "docs",
             "scripts",
             "mix.exs",
             "README.md",
             "LICENSE",
             ".formatter.exs"
           ]

    assert Keyword.fetch!(package, :licenses) == ["Apache-2.0"]

    assert Keyword.fetch!(package, :links) == %{
             "Repository" => "https://github.com/HashNuke/ircxd",
             "Modern IRC" => "https://modern.ircdocs.horse/",
             "IRCv3" => "https://ircv3.net/irc/"
           }
  end

  test "documented verification scripts are executable" do
    repo_root = Path.expand("../..", __DIR__)

    scripts =
      repo_root
      |> Path.join("docs/development.md")
      |> File.read!()
      |> script_paths()
      |> Enum.uniq()
      |> Enum.sort()

    assert scripts == [
             "scripts/run_irssi_manual_check.sh",
             "scripts/run_irssi_server_check.sh",
             "scripts/run_services_integration.sh",
             "scripts/run_standard_replies_integration.sh",
             "scripts/run_verification_gates.sh"
           ]

    assert [] =
             Enum.reject(scripts, fn script ->
               path = Path.join(repo_root, script)
               File.exists?(path) and File.regular?(path) and executable?(path)
             end)
  end

  test "verification gate runner keeps the documented check sequence" do
    runner = File.read!(Path.expand("../../scripts/run_verification_gates.sh", __DIR__))

    expected_steps = [
      "mix format --check-formatted",
      "mix compile --warnings-as-errors",
      "mix test",
      "mix docs",
      "mix hex.build --unpack",
      "==> real standard-replies integration\"\nscripts/run_standard_replies_integration.sh",
      "==> services-backed IRCv3 integration\"\nscripts/run_services_integration.sh",
      "==> irssi cross-client check\"\n  scripts/run_irssi_manual_check.sh"
    ]

    positions =
      Enum.map(expected_steps, fn step ->
        {index, _length} = :binary.match(runner, step)
        index
      end)

    assert positions == Enum.sort(positions)
    assert runner =~ ~s(${IRCXD_INCLUDE_IRSSI:-0})
    assert runner =~ ~s(rm -rf "${PACKAGE_DIR}")
    assert runner =~ "for artifact in docs/*.md; do"
    assert runner =~ ~s(require_package_artifact "${artifact}")
    assert runner =~ "for artifact in scripts/*.sh; do"
    assert runner =~ ~s(require_executable_package_artifact "${artifact}")
  end

  test "real-server integration tests stay opt-in and covered by runners" do
    test_helper = File.read!(Path.expand("../../test/test_helper.exs", __DIR__))

    services_test =
      File.read!(Path.expand("../../test/ircxd/client_services_integration_test.exs", __DIR__))

    standard_replies_test =
      File.read!(
        Path.expand("../../test/ircxd/client_standard_replies_integration_test.exs", __DIR__)
      )

    services_runner =
      File.read!(Path.expand("../../scripts/run_services_integration.sh", __DIR__))

    standard_replies_runner =
      File.read!(Path.expand("../../scripts/run_standard_replies_integration.sh", __DIR__))

    assert test_helper =~
             "exclude: [services_integration: true, standard_replies_integration: true]"

    assert services_test =~ "@moduletag :services_integration"
    assert standard_replies_test =~ "@moduletag :standard_replies_integration"
    assert services_runner =~ "mix test --include services_integration"
    assert standard_replies_runner =~ "mix test --include standard_replies_integration"
  end

  test "verification runner scripts check required external commands" do
    repo_root = Path.expand("../..", __DIR__)

    requirements = %{
      "scripts/run_irssi_manual_check.sh" => ~w(irssi tmux),
      "scripts/run_services_integration.sh" => ~w(atheme-services inspircd perl sudo mix),
      "scripts/run_standard_replies_integration.sh" => ~w(inspircd sudo mix)
    }

    assert [] =
             Enum.reject(requirements, fn {script, commands} ->
               content = File.read!(Path.join(repo_root, script))
               Enum.all?(commands, &String.contains?(content, "require_command #{&1}"))
             end)
  end

  defp document_paths(markdown) do
    code_paths =
      ~r/`((?:lib|test|docs|scripts)\/[^`]+|mix\.exs|README\.md|LICENSE|\.formatter\.exs)`/
      |> Regex.scan(markdown, capture: :all_but_first)
      |> List.flatten()

    link_paths =
      ~r/\]\(((?:lib|test|docs|scripts)\/[^)]+|mix\.exs|README\.md|LICENSE|\.formatter\.exs)\)/
      |> Regex.scan(markdown, capture: :all_but_first)
      |> List.flatten()

    Enum.uniq(code_paths ++ link_paths)
  end

  defp script_paths(markdown) do
    ~r/(scripts\/[A-Za-z0-9_.\/-]+\.sh)/
    |> Regex.scan(markdown, capture: :all_but_first)
    |> List.flatten()
  end

  defp executable?(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mode)
    |> Bitwise.band(0o111) != 0
  end
end
