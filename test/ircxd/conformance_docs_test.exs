defmodule Ircxd.ConformanceDocsTest do
  use ExUnit.Case, async: true

  @allowed_statuses ~w(covered partial host pending)

  test "stable spec matrix keeps stable work classified and evidenced" do
    matrix = File.read!(Path.expand("../../docs/stable_spec_matrix.md", __DIR__))

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
  end

  test "README points contributors at the conformance workflow" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    assert readme =~ "docs/conformance_workflow.md"
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
end
