defmodule Ircxd.ReleaseScriptsTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("..", __DIR__)
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    bin_dir = Path.join(repo, "bin")

    File.mkdir_p!(bin_dir)
    File.cp!(Path.join(@project_root, "bin/bump-version"), Path.join(bin_dir, "bump-version"))
    File.cp!(Path.join(@project_root, "bin/release"), Path.join(bin_dir, "release"))

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project

      @version "1.2.3"

      def project do
        [
          app: :fixture,
          version: @version,
          docs: [source_ref: "v\#{@version}"]
        ]
      end
    end
    """)

    File.write!(Path.join(repo, "README.md"), """
    # Fixture

    [![CI](https://img.shields.io/github/check-suites/example/fixture/v1.2.3?label=CI)](https://github.com/example/fixture/actions/workflows/ci.yml)

    ## Installation

    ```elixir
    def deps do
      [
        {:ircxd, "~> 1.2"},
        {:other, "~> 1.1"}
      ]
    end
    ```
    """)

    %{repo: repo}
  end

  for {part, expected} <- [major: "2.0.0", minor: "1.3.0", patch: "1.2.4"] do
    test "bump-version increments the #{part} SemVer component", %{repo: repo} do
      assert {output, 0} = run(repo, "bin/bump-version", [unquote(to_string(part))])
      assert output =~ "bumped version 1.2.3 -> #{unquote(expected)}"
      mix_exs = File.read!(Path.join(repo, "mix.exs"))
      assert mix_exs =~ ~s(@version "#{unquote(expected)}")
      refute mix_exs =~ ~s(@version "1.2.3")

      readme = File.read!(Path.join(repo, "README.md"))
      assert readme =~ "/v#{unquote(expected)}?label=CI"
      refute readme =~ "/v1.2.3?label=CI"
    end
  end

  test "bump-version rejects unsupported increments without changing the version", %{repo: repo} do
    assert {output, 2} = run(repo, "bin/bump-version", ["prerelease"])
    assert output =~ "usage: bump-version <major|minor|patch>"
    assert File.read!(Path.join(repo, "mix.exs")) =~ ~s(@version "1.2.3")
  end

  test "bump-version rejects a stale CI badge without changing the version", %{repo: repo} do
    readme_path = Path.join(repo, "README.md")
    File.write!(readme_path, String.replace(File.read!(readme_path), "v1.2.3", "v1.2.2"))

    assert {output, 1} = run(repo, "bin/bump-version", ["patch"])
    assert output =~ "CI badge version 1.2.2 does not match 1.2.3"
    assert File.read!(Path.join(repo, "mix.exs")) =~ ~s(@version "1.2.3")
  end

  test "release creates a v-prefixed tag for the project version", %{repo: repo} do
    initialize_repository(repo)

    assert {"created tag v1.2.3\n", 0} = run(repo, "bin/release", [])
    assert {"v1.2.3\n", 0} = System.cmd("git", ["tag", "--list"], cd: repo)

    assert {output, 1} = run(repo, "bin/release", [])
    assert output =~ "tag already exists locally: v1.2.3"
  end

  test "release rejects a tag that already exists on origin", %{repo: repo, tmp_dir: tmp_dir} do
    origin = Path.join(tmp_dir, "origin.git")
    initialize_repository(repo, origin)
    assert {_, 0} = System.cmd("git", ["tag", "v1.2.3"], cd: repo)
    assert {_, 0} = System.cmd("git", ["push", "origin", "v1.2.3"], cd: repo)
    assert {_, 0} = System.cmd("git", ["tag", "--delete", "v1.2.3"], cd: repo)

    assert {output, 1} = run(repo, "bin/release", [])
    assert output =~ "tag already exists on origin: v1.2.3"
  end

  for {version, requirement} <- [{"2.0.0", "2.0"}, {"1.3.0", "1.3"}, {"1.2.4", "1.2"}] do
    test "release synchronizes installation for #{version} before tagging", %{repo: repo} do
      mix_path = Path.join(repo, "mix.exs")
      readme_path = Path.join(repo, "README.md")
      File.write!(mix_path, String.replace(File.read!(mix_path), "1.2.3", unquote(version)))

      readme =
        String.replace(File.read!(readme_path), ~s({:ircxd, "~> 1.2"}), ~s({:ircxd, "~> 1.1"}))

      File.write!(readme_path, readme)
      initialize_repository(repo)

      assert {output, 1} = run(repo, "bin/release", [])
      assert output =~ "commit mix.exs and README.md changes, then rerun bin/release"

      expected =
        String.replace(readme, ~s({:ircxd, "~> 1.1"}), ~s({:ircxd, "~> #{unquote(requirement)}"}))

      assert File.read!(readme_path) == expected
      assert {"", 0} = System.cmd("git", ["tag", "--list"], cd: repo)

      assert {_, 1} = run(repo, "bin/release", [])
      assert {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo)
      assert {_, 0} = System.cmd("git", ["commit", "-m", "Update installation"], cd: repo)
      assert {"created tag v#{unquote(version)}\n", 0} = run(repo, "bin/release", [])

      assert {^expected, 0} =
               System.cmd("git", ["show", "v#{unquote(version)}:README.md"], cd: repo)
    end
  end

  for staged? <- [false, true] do
    test "release requires committed README changes (staged: #{staged?})", %{repo: repo} do
      initialize_repository(repo)
      File.write!(Path.join(repo, "README.md"), "\nRelease notes\n", [:append])

      if unquote(staged?) do
        assert {_, 0} = System.cmd("git", ["add", "README.md"], cd: repo)
      end

      assert {output, 1} = run(repo, "bin/release", [])
      assert output =~ "commit mix.exs and README.md changes, then rerun bin/release"
      assert {"", 0} = System.cmd("git", ["tag", "--list"], cd: repo)
    end
  end

  test "release requires a committed project version", %{repo: repo} do
    initialize_repository(repo)
    mix_path = Path.join(repo, "mix.exs")
    File.write!(mix_path, String.replace(File.read!(mix_path), "1.2.3", "1.2.4"))

    assert {output, 1} = run(repo, "bin/release", [])
    assert output =~ "commit mix.exs and README.md changes, then rerun bin/release"
    assert {"", 0} = System.cmd("git", ["tag", "--list"], cd: repo)
  end

  for count <- [0, 2] do
    test "release rejects #{count} installation requirements without changing the README", %{
      repo: repo
    } do
      readme_path = Path.join(repo, "README.md")

      readme =
        String.replace(
          File.read!(readme_path),
          ~s({:ircxd, "~> 1.2"}),
          String.duplicate(~s({:ircxd, "~> 1.1"}), unquote(count))
        )

      File.write!(readme_path, readme)
      initialize_repository(repo)

      assert {output, 1} = run(repo, "bin/release", [])
      assert output =~ "expected exactly one ircxd installation requirement"
      assert File.read!(readme_path) == readme
      assert {"", 0} = System.cmd("git", ["tag", "--list"], cd: repo)
    end
  end

  defp initialize_repository(repo, origin \\ nil) do
    assert {_, 0} = System.cmd("git", ["init", "--initial-branch=main"], cd: repo)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "test@example.test"], cd: repo)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Release Test"], cd: repo)
    assert {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "fixture"], cd: repo)

    if origin do
      assert {_, 0} = System.cmd("git", ["init", "--bare", origin])
      assert {_, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: repo)
    end
  end

  defp run(repo, executable, args) do
    System.cmd(Path.join(repo, executable), args, cd: repo, stderr_to_stdout: true)
  end
end
