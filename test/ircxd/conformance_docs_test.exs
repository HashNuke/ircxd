defmodule Ircxd.ConformanceDocsTest do
  use ExUnit.Case, async: true

  @allowed_statuses ~w(covered partial host pending)

  test "stable spec matrix keeps stable work classified and evidenced" do
    matrix = File.read!(Path.expand("../../docs/stable_spec_matrix.md", __DIR__))
    repo_root = Path.expand("../..", __DIR__)

    rows =
      matrix
      |> String.split("\n")
      |> Enum.flat_map(&parse_matrix_row/1)

    assert rows != []

    assert [] =
             Enum.reject(rows, fn row ->
               row.status in @allowed_statuses
             end)

    assert [] =
             Enum.filter(rows, fn row ->
               row.status in ["partial", "pending"]
             end)

    assert [] =
             Enum.filter(rows, fn row ->
               row.evidence in ["", "TBD", "None"]
             end)

    missing_paths =
      rows
      |> Enum.flat_map(&evidence_paths/1)
      |> Enum.reject(&File.exists?(Path.join(repo_root, &1)))

    assert [] = missing_paths
  end

  test "README points contributors at the conformance workflow" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    assert readme =~ "docs/conformance_workflow.md"
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

  test "completion audit evidence points to existing artifacts" do
    audit = File.read!(Path.expand("../../docs/completion_audit.md", __DIR__))
    repo_root = Path.expand("../..", __DIR__)

    missing_paths =
      audit
      |> document_paths()
      |> Enum.reject(&File.exists?(Path.join(repo_root, &1)))

    assert [] = missing_paths
  end

  test "spec audit evidence points to existing artifacts" do
    audit = File.read!(Path.expand("../../docs/spec_audit.md", __DIR__))
    repo_root = Path.expand("../..", __DIR__)

    missing_paths =
      audit
      |> document_paths()
      |> Enum.reject(&File.exists?(Path.join(repo_root, &1)))

    assert [] = missing_paths
  end

  test "IRCv3 index audit references point to existing artifacts" do
    audit = File.read!(Path.expand("../../docs/ircv3_index_audit.md", __DIR__))
    repo_root = Path.expand("../..", __DIR__)

    missing_paths =
      audit
      |> document_paths()
      |> Enum.reject(&File.exists?(Path.join(repo_root, &1)))

    assert [] = missing_paths
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
    package =
      Ircxd.MixProject.project()
      |> Keyword.fetch!(:package)

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
      [
        "README.md",
        "docs/completion_audit.md",
        "docs/conformance_workflow.md",
        "docs/spec_audit.md"
      ]
      |> Enum.map(&File.read!(Path.join(repo_root, &1)))
      |> Enum.flat_map(&script_paths/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert scripts == [
             "scripts/run_irssi_manual_check.sh",
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
      expected_steps
      |> Enum.map(fn step ->
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

               Enum.all?(commands, fn command ->
                 content =~ "require_command #{command}"
               end)
             end)
  end

  defp parse_matrix_row("| Area | Status | Evidence | Next grouped work |"), do: []
  defp parse_matrix_row("| --- | --- | --- | --- |"), do: []

  defp parse_matrix_row(line) do
    case Regex.run(
           ~r/^\| (?<area>[^|]+) \| (?<status>[^|]+) \| (?<evidence>[^|]+) \| (?<next>[^|]+) \|$/,
           line,
           capture: :all_names
         ) do
      [area, evidence, next, status] ->
        [
          %{
            area: String.trim(area),
            evidence: String.trim(evidence),
            next: String.trim(next),
            status: String.trim(status)
          }
        ]

      nil ->
        []
    end
  end

  defp evidence_paths(row) do
    ~r/`([^`]+\.(?:ex|exs|md))`/
    |> Regex.scan(row.evidence, capture: :all_but_first)
    |> List.flatten()
  end

  defp document_paths(markdown) do
    ~r/`((?:lib|test|docs|scripts)\/[^`]+|mix\.exs|README\.md|LICENSE|\.formatter\.exs)`/
    |> Regex.scan(markdown, capture: :all_but_first)
    |> List.flatten()
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
