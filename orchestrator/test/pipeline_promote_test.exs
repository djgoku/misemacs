defmodule PipelinePromoteTest do
  use ExUnit.Case, async: false

  @tag_name "v2026.9.0"
  @asset "misemacs-v2026.9.0-macos-arm64.tar.gz"

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
        printf '%s\n' packslip.sigstore.json misemacs-v2026.9.0-macos-arm64.tar.gz
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
    on_exit(fn -> File.rm_rf!(root) end)
    %{bin: bin, log: log, manifest: manifest}
  end

  test "refuses Latest when Packslip verification fails", ctx do
    {_, status} = promote(ctx, verify_exit: 1)

    assert status != 0
    calls = File.read!(ctx.log)
    assert calls =~ "verify "
    refute calls =~ "release upload"
    refute calls =~ "release edit"
  end

  test "refuses a validly signed bundle for a different project", ctx do
    {_, status} = promote(ctx, project: "github.com/other/repo")

    assert status != 0
    refute File.read!(ctx.log) =~ "release edit"
  end

  test "promotes only after verifying the expected archive and release", ctx do
    {_, 0} = promote(ctx)

    calls = File.read!(ctx.log)

    assert calls =~
             "--identity https://github.com/owner/source-emacs-master/.github/workflows/packslip.yml@refs/tags/#{@tag_name}"

    assert calls =~ "--artifact "
    assert calls =~ @asset
    assert calls =~ "release upload"
    assert calls =~ "release edit #{@tag_name}"
  end

  test "verifies a latest tag only once when it also appears in attached tags", ctx do
    {_, 0} = promote(ctx, attach: @tag_name)

    verify_calls =
      ctx.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "verify "))

    assert verify_calls == 1
  end

  defp promote(ctx, options \\ []) do
    statement = %{
      predicate: %{
        project: Keyword.get(options, :project, "github.com/owner/source-emacs-master"),
        version: "2026.9.0",
        source: %{repo: "https://github.com/owner/source-emacs-master", tag: @tag_name}
      }
    }

    args = [
      Path.expand("../../pipeline/promote", __DIR__),
      "--repo",
      "owner/source-emacs-master",
      "--tag",
      @tag_name,
      "--channel",
      "master",
      "--manifest",
      ctx.manifest
    ]

    args =
      if Keyword.has_key?(options, :attach),
        do: args ++ ["--attach", options[:attach]],
        else: args

    System.cmd(
      "bash",
      args,
      env: [
        {"PATH", "#{ctx.bin}:#{System.get_env("PATH")}"},
        {"MOCK_LOG", ctx.log},
        {"MISEMACS_ARTIFACT_BASE", "owner/source"},
        {"PACKSLIP_VERIFY_EXIT", to_string(Keyword.get(options, :verify_exit, 0))},
        {"PACKSLIP_STATEMENT", statement |> :json.encode() |> IO.iodata_to_binary()}
      ],
      stderr_to_stdout: true
    )
  end
end
