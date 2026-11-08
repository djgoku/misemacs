defmodule Mix.Tasks.Release.PromoteTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Mix.Tasks.Release.Promote

  @tag_name "v2026.9.0"
  @asset "misemacs-v2026.9.0-macos-arm64.tar.gz"
  @repo "owner/source-emacs-master"

  setup do
    root = Path.join(System.tmp_dir!(), "misemacs-promote-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    log = Path.join(root, "calls.log")
    manifest = Path.join(root, "build-manifest.json")
    File.write!(manifest, "{}")
    File.write!(log, "")

    File.write!(Path.join(bin, "gh"), ~S"""
    #!/usr/bin/env bash
    set -euo pipefail
    case "$1 $2" in
      "release view")
        printf '{"assets":[{"name":"packslip.sigstore.json"},{"name":"misemacs-v2026.9.0-macos-arm64.tar.gz"}]}\n'
        ;;
      "release download")
        shift 2
        dir=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --dir|-D) dir="$2"; shift 2 ;;
            --pattern|-p) mkdir -p "$dir"; printf 'fixture\n' > "$dir/$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        ;;
      "release upload"|"release edit")
        printf '%s\n' "$1 $2 $3" >> "$MOCK_LOG"
        ;;
      *) exit 2 ;;
    esac
    """)

    File.write!(Path.join(bin, "packslip"), ~S"""
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$*" >> "$MOCK_LOG"
    case "$1" in
      verify) exit "$PACKSLIP_VERIFY_EXIT" ;;
      show) printf '%s\n' "$PACKSLIP_STATEMENT" ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)
    File.chmod!(Path.join(bin, "packslip"), 0o755)

    saved = Map.new(~w(PATH MOCK_LOG MISEMACS_ARTIFACT_BASE), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(root)
    end)

    System.put_env(%{
      "PATH" => "#{bin}:#{System.get_env("PATH")}",
      "MOCK_LOG" => log,
      "MISEMACS_ARTIFACT_BASE" => "owner/source"
    })

    %{log: log, manifest: manifest}
  end

  test "refuses Latest when Packslip verification fails", ctx do
    assert_raise Mix.Error, ~r/packslip verify/, fn -> promote(ctx, verify_exit: 1) end

    calls = File.read!(ctx.log)
    assert calls =~ "verify "
    refute calls =~ "release upload"
    refute calls =~ "release edit"
  end

  test "refuses a validly signed bundle for a different project", ctx do
    assert_raise Mix.Error, ~r/different project/, fn ->
      promote(ctx, project: "github.com/other/repo")
    end

    refute File.read!(ctx.log) =~ "release edit"
  end

  test "refuses a repo that is not the channel's artifact repo", ctx do
    assert_raise Mix.Error, ~r/expected 'owner\/source-emacs-31'/, fn ->
      promote(ctx, channel: "31")
    end

    assert File.read!(ctx.log) == ""
  end

  test "promotes only after verifying the expected archive and release", ctx do
    promote(ctx)

    calls = File.read!(ctx.log)

    assert calls =~
             "--identity https://github.com/#{@repo}/.github/workflows/packslip.yml@refs/tags/#{@tag_name}"

    assert calls =~ "--artifact "
    assert calls =~ @asset
    assert calls =~ "release upload #{@tag_name}"
    assert calls =~ "release edit #{@tag_name}"
  end

  test "verifies a latest tag only once when it also appears in attached tags", ctx do
    promote(ctx, attach: @tag_name)

    lines = ctx.log |> File.read!() |> String.split("\n")
    assert Enum.count(lines, &String.starts_with?(&1, "verify ")) == 1
    assert Enum.count(lines, &String.starts_with?(&1, "release upload")) == 1
  end

  test "statement_matches? requires project, version, source repo and tag to agree" do
    good = statement("github.com/#{@repo}", "2026.9.0", @tag_name)
    assert Promote.statement_matches?(good, @repo, @tag_name)

    refute Promote.statement_matches?(
             statement("github.com/x/y", "2026.9.0", @tag_name),
             @repo,
             @tag_name
           )

    refute Promote.statement_matches?(
             statement("github.com/#{@repo}", "2026.9.1", @tag_name),
             @repo,
             @tag_name
           )

    refute Promote.statement_matches?(
             statement("github.com/#{@repo}", "2026.9.0", "v2026.9.1"),
             @repo,
             @tag_name
           )

    refute Promote.statement_matches?(%{}, @repo, @tag_name)
  end

  defp statement(project, version, tag) do
    %{
      "predicate" => %{
        "project" => project,
        "version" => version,
        "source" => %{"repo" => "https://github.com/#{@repo}", "tag" => tag}
      }
    }
  end

  defp promote(ctx, options \\ []) do
    statement =
      statement(Keyword.get(options, :project, "github.com/#{@repo}"), "2026.9.0", @tag_name)

    System.put_env("PACKSLIP_VERIFY_EXIT", to_string(Keyword.get(options, :verify_exit, 0)))
    System.put_env("PACKSLIP_STATEMENT", JSON.encode!(statement))

    args =
      ["--repo", @repo, "--tag", @tag_name, "--manifest", ctx.manifest] ++
        ["--channel", Keyword.get(options, :channel, "master")] ++
        if(options[:attach], do: ["--attach", options[:attach]], else: [])

    capture_io(fn -> Mix.Task.rerun("release.promote", args) end)
  end
end
