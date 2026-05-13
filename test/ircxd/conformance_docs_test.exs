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
end
