# Phase 4 — Package + Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the path from the relocated+signed `build/master/Emacs.app` to a clean Mac running it via `mise use aqua:djgoku/misemacs@<tag>` — package, publish, promote, E2E-validate (lab first, then the gated real repo), leaving `djgoku/misemacs` unchanged at the end (G2).

**Architecture:** Spec: `docs/superpowers/specs/2026-06-11-phase-4-package-publish-design.md` (decisions G1–G8, evidence P1–P14). Bash pipeline stages (`package`/`publish`/`promote`) do all `gh` IO; two network-free mix tasks (`release.names`, `release.manifest`) are the only way name strings and fingerprints are produced (sole-owner rule); the consumed aqua registry is vendored at `aqua/registry.yaml` and bound to `Orchestrator.Naming` by a contract test. E2E runs inside a fresh pregate VM (`pregate --macos --cmd`, the Phase-3 pattern). Real-repo mutations: publish → validate → cleanup, each behind an explicit user gate + `MISEMACS_PUBLISH_OK=1` interlock.

**Tech Stack:** bash, gh 2.92, Elixir 1.20 (built-in `JSON`, ExUnit, existing `Orchestrator.{Naming,Core.Tag,Core.Hash,Manifest}`), mise tasks, pregate + tart (macOS VM), throwaway lab repo `djgoku/misemacs-phase4-lab` (public).

**Execution context:** Run in an isolated worktree (superpowers:using-git-worktrees), branch name suggestion `worktree-phase-4-package-publish`. The user signs commits (YubiKey touch per commit — batch thoughtfully, don't amend). NEVER run `gh` mutations against `djgoku/misemacs` except in Task 11 with the user's in-the-moment approval; everything else targets the lab repo. `git push` / merges are the user's.

---

## Task 1: Reuse the Phase-3 artifact (no rebuild)

The relocated, signed, transport-proven app + its source checkout already exist in the `modest-payne-854333` worktree (`Emacs.app`, `conda-prefix-lib.txt`, `otool-prereloc.txt`, `src/` at `8decb65`). `build/` is gitignored, so copy it into this worktree.

**Files:** none committed (gitignored artifact).

- [ ] **Step 1: Clone the build dir in (APFS clone, ~instant)**

```bash
cd "$(git rev-parse --show-toplevel)"   # the phase-4 worktree root
mkdir -p build
cp -Rc /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/modest-payne-854333/build/master build/master
```

- [ ] **Step 2: Verify the artifact is alive and src is a checkout**

```bash
build/master/Emacs.app/Contents/MacOS/Emacs --batch --eval '(princ (format "ok %s\n" emacs-version))'
git -C build/master/src rev-parse HEAD
```

Expected: `ok 32.0.50` (or current master version) and a full sha (`8decb65…`). If the `--batch` fails, STOP — the artifact is corrupt; re-run `mise run build && mise run relocate` instead of debugging the copy.

## Task 2: Vendor `aqua/registry.yaml` + registry contract test

**Files:**
- Create: `aqua/registry.yaml`
- Test: `orchestrator/test/orchestrator/registry_contract_test.exs`

- [ ] **Step 1: Write the failing contract test**

`orchestrator/test/orchestrator/registry_contract_test.exs`:

```elixir
defmodule Orchestrator.RegistryContractTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @moduledoc """
  Binds the VENDORED consumer registry (aqua/registry.yaml — what
  MISE_AQUA_REGISTRY_URL serves from this repo's main) to Orchestrator.Naming.
  Line-presence checks on the small, stable YAML — deliberately no YAML dep.
  Drift in either direction must break the suite (spec G5/P7).
  """

  @registry_path Path.expand("../../../aqua/registry.yaml", __DIR__)

  setup_all do
    %{registry: File.read!(@registry_path)}
  end

  test "registry file exists at the consumed path" do
    assert File.exists?(@registry_path)
  end

  test "asset template + format + os replacement are present verbatim", %{registry: reg} do
    assert reg =~ "asset: misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz"
    assert reg =~ "format: tar.gz"
    assert reg =~ "darwin: macos"
    assert reg =~ "repo_owner: djgoku"
    assert reg =~ "repo_name: misemacs"
  end

  test "checksum contract matches Naming.checksums_filename/0", %{registry: reg} do
    assert reg =~ "asset: #{Naming.checksums_filename()}"
    assert reg =~ "algorithm: sha256"
    assert reg =~ "type: github_release"
  end

  test "rendering the registry template == Naming.asset_name/3 (darwin->macos, arm64)" do
    tag = "emacs-master-2026-06-11"

    rendered =
      "misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz"
      |> String.replace("{{.Version}}", tag)
      |> String.replace("{{.OS}}", "macos")
      |> String.replace("{{.Arch}}", "arm64")

    assert rendered == Naming.asset_name(tag, "macos", "arm64")
  end

  test "every Naming.bundle_binaries/0 path appears as a files src entry", %{registry: reg} do
    for bin <- Naming.bundle_binaries() do
      assert reg =~ ~s(src: "{{.AssetWithoutExt}}/#{bin}"),
             "registry is missing files src for #{bin}"
    end
  end

  test "supported env is darwin/arm64 only", %{registry: reg} do
    assert reg =~ "- darwin/arm64"
  end
end
```

- [ ] **Step 2: Run it — must fail (no registry file yet)**

Run: `mise run test`
Expected: FAIL — `File.read!` raises `File.Error` for `aqua/registry.yaml` (setup_all), other suites green.

- [ ] **Step 3: Vendor the registry file (verbatim copy of what the consumed URL serves today — P7/G5)**

`aqua/registry.yaml`:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/aquaproj/aqua/main/json-schema/registry.json
packages:
  - type: github_release
    repo_owner: djgoku
    repo_name: misemacs
    description: Hermetically-built relocatable Emacs.app for macOS, via mise + conda-forge
    asset: misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz
    format: tar.gz
    checksum:
      type: github_release
      asset: SHASUMS256.txt
      algorithm: sha256
    supported_envs:
      - darwin/arm64
    overrides:
      - goos: darwin
        files:
          - name: emacs
            src: "{{.AssetWithoutExt}}/Emacs.app/Contents/MacOS/Emacs"
          - name: emacsclient
            src: "{{.AssetWithoutExt}}/Emacs.app/Contents/MacOS/bin/emacsclient"
          - name: etags
            src: "{{.AssetWithoutExt}}/Emacs.app/Contents/MacOS/bin/etags"
          - name: ebrowse
            src: "{{.AssetWithoutExt}}/Emacs.app/Contents/MacOS/bin/ebrowse"
    replacements:
      darwin: macos
```

- [ ] **Step 4: Run tests — pass**

Run: `mise run test`
Expected: PASS (58 existing + 6 new).

- [ ] **Step 5: Commit**

```bash
git add aqua/registry.yaml orchestrator/test/orchestrator/registry_contract_test.exs
git commit -m "feat(phase4): vendor consumed aqua registry + Naming contract test (G5/P7)"
```

## Task 3: `mix release.names` (two modes)

**Files:**
- Create: `orchestrator/lib/mix/tasks/release.names.ex`
- Test: `orchestrator/test/mix/tasks/release_names_test.exs`

- [ ] **Step 1: Write the failing tests**

`orchestrator/test/mix/tasks/release_names_test.exs`:

```elixir
defmodule Mix.Tasks.Release.NamesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @base_args ~w(--os macos --arch arm64)

  defp run(args) do
    capture_io(fn -> Mix.Task.rerun("release.names", args) end)
  end

  defp kv(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "="))
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.reduce(%{}, fn [k, v], acc ->
      Map.update(acc, k, [v], &(&1 ++ [v]))
    end)
  end

  test "given-tag mode emits names for the explicit tag, no snapshot needed" do
    out = kv(run(["--tag", "emacs-master-2026-06-11" | @base_args]))
    assert out["tag"] == ["emacs-master-2026-06-11"]
    assert out["asset"] == ["misemacs-emacs-master-2026-06-11-macos-arm64.tar.gz"]
    assert out["stem"] == ["misemacs-emacs-master-2026-06-11-macos-arm64"]
    assert out["checksums"] == ["SHASUMS256.txt"]
  end

  test "given-tag mode works for arbitrary sentinel tags (pregate)" do
    out = kv(run(["--tag", "pregate-smoke" | @base_args]))
    assert out["asset"] == ["misemacs-pregate-smoke-macos-arm64.tar.gz"]
  end

  test "bin= lines are exactly Naming.bundle_binaries/0 in order" do
    out = kv(run(["--tag", "t" | @base_args]))
    assert out["bin"] == Orchestrator.Naming.bundle_binaries()
  end

  test "snapshot mode computes the tag via Core.Tag (no collision)" do
    tags = write_tags(["emacs-master-2026-06-10"])
    out = kv(run(["--channel", "master", "--date", "2026-06-11", "--tags-file", tags | @base_args]))
    assert out["tag"] == ["emacs-master-2026-06-11"]
  end

  test "snapshot mode appends .N on same-day collision" do
    tags = write_tags(["emacs-master-2026-06-11", "emacs-master-2026-06-11.1"])
    out = kv(run(["--channel", "master", "--date", "2026-06-11", "--tags-file", tags | @base_args]))
    assert out["tag"] == ["emacs-master-2026-06-11.2"]
    assert out["asset"] == ["misemacs-emacs-master-2026-06-11.2-macos-arm64.tar.gz"]
  end

  test "snapshot mode reads the snapshot from stdin with --tags-file -" do
    out =
      capture_io("emacs-master-2026-06-11\n", fn ->
        Mix.Task.rerun(
          "release.names",
          ["--channel", "master", "--date", "2026-06-11", "--tags-file", "-" | @base_args]
        )
      end)

    assert kv(out)["tag"] == ["emacs-master-2026-06-11.1"]
  end

  test "raises without --os/--arch" do
    assert_raise Mix.Error, fn -> run(["--tag", "t", "--os", "macos"]) end
  end

  test "raises when neither --tag nor --channel mode is complete" do
    assert_raise Mix.Error, fn -> run(@base_args) end
    assert_raise Mix.Error, fn -> run(["--channel", "master" | @base_args]) end
  end

  defp write_tags(tags) do
    path = Path.join(System.tmp_dir!(), "tags-#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.join(tags, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
```

- [ ] **Step 2: Run — must fail**

Run: `mise run test`
Expected: FAIL — `The task "release.names" could not be found`.

- [ ] **Step 3: Implement the task**

`orchestrator/lib/mix/tasks/release.names.ex`:

```elixir
defmodule Mix.Tasks.Release.Names do
  @shortdoc "Print release tag/asset/stem/checksums/bin names (snapshot or given-tag mode)"
  @moduledoc """
  Sole bash-facing source of release name strings (spec §4.2). Network-free.

      # snapshot mode (publish computes the next tag, .N on collision):
      mix release.names --channel master --date 2026-06-11 --os macos --arch arm64 --tags-file -

      # given-tag mode (package / pregate sentinel — skips Core.Tag):
      mix release.names --tag emacs-master-2026-06-11 --os macos --arch arm64

  Output: `key=value` lines — tag, asset, stem, checksums, then one `bin=` line
  per `Naming.bundle_binaries/0` entry. Bash must parse, never re-derive.
  """
  use Mix.Task
  alias Orchestrator.{Core.Tag, Naming}

  @switches [channel: :string, date: :string, os: :string, arch: :string, tags_file: :string, tag: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    os = required(opts, :os)
    arch = required(opts, :arch)
    tag = resolve_tag(opts)

    IO.puts("tag=#{tag}")
    IO.puts("asset=#{Naming.asset_name(tag, os, arch)}")
    IO.puts("stem=#{Naming.asset_stem(tag, os, arch)}")
    IO.puts("checksums=#{Naming.checksums_filename()}")
    Enum.each(Naming.bundle_binaries(), &IO.puts("bin=#{&1}"))
  end

  defp resolve_tag(opts) do
    case {opts[:tag], opts[:channel]} do
      {tag, nil} when is_binary(tag) ->
        tag

      {nil, channel} when is_binary(channel) ->
        Tag.next_tag(channel, required(opts, :date), read_tags(required(opts, :tags_file)))

      _ ->
        Mix.raise("usage: --tag <tag> | --channel <ch> --date <YYYY-MM-DD> --tags-file <path|->")
    end
  end

  defp read_tags("-") do
    case IO.read(:stdio, :eof) do
      :eof -> []
      data -> split_tags(data)
    end
  end

  defp read_tags(path), do: path |> File.read!() |> split_tags()

  defp split_tags(data), do: data |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

  defp required(opts, key) do
    opts[key] || Mix.raise("missing required --#{key |> Atom.to_string() |> String.replace("_", "-")}")
  end
end
```

- [ ] **Step 4: Run — pass**

Run: `mise run test`
Expected: PASS (8 new tests green).

- [ ] **Step 5: Format + commit**

```bash
mise run fmt
git add orchestrator/lib/mix/tasks/release.names.ex orchestrator/test/mix/tasks/release_names_test.exs
git commit -m "feat(phase4): mix release.names — snapshot + given-tag modes (spec 4.2)"
```

## Task 4: `mix release.manifest`

**Files:**
- Create: `orchestrator/lib/mix/tasks/release.manifest.ex`
- Test: `orchestrator/test/mix/tasks/release_manifest_test.exs`

- [ ] **Step 1: Write the failing tests**

`orchestrator/test/mix/tasks/release_manifest_test.exs`:

```elixir
defmodule Mix.Tasks.Release.ManifestTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Orchestrator.Core.Hash

  setup do
    root = Path.join(System.tmp_dir!(), "manifest-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "versions/master"))
    File.write!(Path.join(root, "mise.toml"), "# repo mise.toml\n")
    File.write!(Path.join(root, "mise.lock"), "# repo mise.lock\n")
    File.write!(Path.join(root, "versions.toml"), """
    [versions.master]
    ref = "master"
    channel = "master"
    """)
    File.write!(Path.join(root, "versions/master/mise.toml"), "# v mise\n")
    File.write!(Path.join(root, "versions/master/pixi.toml"), "# v pixi\n")
    File.write!(Path.join(root, "versions/master/pixi.lock"), "# v lock\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, out: Path.join(root, "build-manifest.json")}
  end

  defp run(root, out, extra \\ []) do
    args =
      ["--root", root, "--out", out, "--version", "master", "--tag", "emacs-master-2026-06-11",
       "--upstream-sha", "abc123"] ++ extra

    capture_io(fn -> Mix.Task.rerun("release.manifest", args) end)
  end

  test "writes the schema-1 manifest with the Core.Hash fingerprint", %{root: root, out: out} do
    run(root, out)
    manifest = out |> File.read!() |> JSON.decode!()

    assert manifest["schema"] == 1
    entry = manifest["versions"]["master"]
    assert entry["ref"] == "master"
    assert entry["released_tag"] == "emacs-master-2026-06-11"
    assert entry["upstream_sha"] == "abc123"

    expected =
      Hash.version_fingerprint(%{
        toolchain_hash: Hash.toolchain_hash("# repo mise.toml\n", "# repo mise.lock\n"),
        upstream_sha: "abc123",
        mise_toml: "# v mise\n",
        pixi_toml: "# v pixi\n",
        pixi_lock: "# v lock\n"
      })

    assert entry["inputs_hash"] == expected
  end

  test "fails loudly for a version missing from versions.toml", %{root: root, out: out} do
    assert_raise Mix.Error, ~r/no such version/, fn ->
      capture_io(fn ->
        Mix.Task.rerun("release.manifest", [
          "--root", root, "--out", out, "--version", "nope",
          "--tag", "t", "--upstream-sha", "abc"
        ])
      end)
    end
  end

  test "fails loudly on a missing input file", %{root: root, out: out} do
    File.rm!(Path.join(root, "versions/master/pixi.lock"))
    assert_raise File.Error, fn -> run(root, out) end
  end
end
```

- [ ] **Step 2: Run — must fail**

Run: `mise run test`
Expected: FAIL — `The task "release.manifest" could not be found`.

- [ ] **Step 3: Implement the task**

`orchestrator/lib/mix/tasks/release.manifest.ex`:

```elixir
defmodule Mix.Tasks.Release.Manifest do
  @shortdoc "Write the schema-1 build-manifest.json for one released version"
  @moduledoc """
  Emits the §7.2 state manifest using the SAME `Core.Hash` §8 fingerprint that
  Phase 5's detect will recompute (over the same input set — Decision E extends
  `toolchain_hash` there). Network-free; the only IO is reading the committed
  input files and writing `--out`.

      mix release.manifest --version master --tag <tag> --upstream-sha <sha> \\
                           --out ../dist/master/build-manifest.json [--root ..]
  """
  use Mix.Task
  alias Orchestrator.{Core.Hash, Manifest}

  @switches [version: :string, tag: :string, upstream_sha: :string, out: :string, root: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    version = required(opts, :version)
    tag = required(opts, :tag)
    sha = required(opts, :upstream_sha)
    out = required(opts, :out)
    root = opts[:root] || ".."

    ref = ref_for!(root, version)

    [mise_toml, pixi_toml, pixi_lock] =
      version
      |> Manifest.version_input_files()
      |> Enum.map(&File.read!(Path.join(root, &1)))

    inputs_hash =
      Hash.version_fingerprint(%{
        toolchain_hash:
          Hash.toolchain_hash(
            File.read!(Path.join(root, "mise.toml")),
            File.read!(Path.join(root, "mise.lock"))
          ),
        upstream_sha: sha,
        mise_toml: mise_toml,
        pixi_toml: pixi_toml,
        pixi_lock: pixi_lock
      })

    manifest = %{
      "schema" => 1,
      "versions" => %{
        version => %{
          "ref" => ref,
          "upstream_sha" => sha,
          "inputs_hash" => inputs_hash,
          "released_tag" => tag
        }
      }
    }

    File.write!(out, JSON.encode!(manifest) <> "\n")
    IO.puts("wrote #{out}")
  end

  defp ref_for!(root, version) do
    # Toml.decode/1 (non-bang) is the form Manifest.load already uses — proven API.
    with {:ok, map} <- Toml.decode(File.read!(Path.join(root, "versions.toml"))),
         %{"ref" => ref} <- get_in(map, ["versions", version]) do
      ref
    else
      _ -> Mix.raise("no such version #{inspect(version)} in versions.toml")
    end
  end

  defp required(opts, key) do
    opts[key] || Mix.raise("missing required --#{key |> Atom.to_string() |> String.replace("_", "-")}")
  end
end
```

- [ ] **Step 4: Run — pass**

Run: `mise run test`
Expected: PASS (3 new tests green).

- [ ] **Step 5: Format + commit**

```bash
mise run fmt
git add orchestrator/lib/mix/tasks/release.manifest.ex orchestrator/test/mix/tasks/release_manifest_test.exs
git commit -m "feat(phase4): mix release.manifest — schema-1 state manifest via Core.Hash (spec 4.3)"
```

## Task 5: `pipeline/package` + mise task + pregate step

> **Review deviation (2026-06-12):** the as-committed `pipeline/package` differs from the
> script block below in two reviewed fixes: step [6] greps a listing FILE instead of piping
> `echo "$listing" | grep -q` (pipefail+SIGPIPE made verdicts tar-entry-order-dependent —
> proven false-FATAL/missed-detection on the real 413KB listing), and the step-[4] `cp -Rp`
> fallback now `rm -rf`s the partial clone dest first (nesting hazard) without discarding
> stderr. Plus: CHECKSUMS in the parse guard, EXIT trap for the extract tmpdir, anchored
> `/dist/` in .gitignore, `--upstream-sha` in the task description.

**Files:**
- Create: `pipeline/package`
- Modify: `mise.toml` (add `[tasks.package]`), `.gitignore` (add `dist/`), `.pregate/macos.sh` (append sentinel package run)

- [ ] **Step 1: Write the script**

`pipeline/package` (mode 0755):

```bash
#!/usr/bin/env bash
# pipeline/package <version> <tag> [--upstream-sha <sha>] — turn the relocated+signed
# build/<version>/Emacs.app into the contractual release artifact (spec §4.4):
#   dist/<version>/{<asset>, SHASUMS256.txt, upstream-sha.txt}
# CHECKS the bundle (never mutates — nothing touches it after Phase 2/3 sign+verify),
# tars WITHOUT xattrs (E7), then SELF-VERIFIES the artifact locally before any gh call.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: pipeline/package <version> <tag> [--upstream-sha <sha>]}"
TAG="${2:?usage: pipeline/package <version> <tag> [--upstream-sha <sha>]}"
shift 2
UPSTREAM_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream-sha) UPSTREAM_SHA="${2:?--upstream-sha needs a value}"; shift 2 ;;
    *) echo "FATAL: unknown arg $1"; exit 1 ;;
  esac
done
OUT="$HERE/build/$VERSION"; APP="$OUT/Emacs.app"; DIST="$HERE/dist/$VERSION"
[ -d "$APP" ] || { echo "FATAL: $APP missing — run 'mise run build && mise run relocate' first"; exit 1; }

echo ">> [1] names for tag '$TAG' (given-tag mode — Naming is the sole owner)"
ASSET=""; STEM=""; CHECKSUMS=""; BINS=()
while IFS= read -r line; do
  case "$line" in
    asset=*)     ASSET="${line#asset=}" ;;
    stem=*)      STEM="${line#stem=}" ;;
    checksums=*) CHECKSUMS="${line#checksums=}" ;;
    bin=*)       BINS+=("${line#bin=}") ;;
  esac
done < <(cd "$HERE/orchestrator" && mise exec -- mix release.names --tag "$TAG" --os macos --arch arm64)
[ -n "$ASSET" ] && [ -n "$STEM" ] && [ "${#BINS[@]}" -ge 4 ] || { echo "FATAL: release.names output incomplete"; exit 1; }

echo ">> [2] layout check (spec §10; check-only, the bundle is sealed)"
for bin in "${BINS[@]}"; do
  [ -x "$OUT/$bin" ] || { echo "FATAL: missing/non-executable $bin in $OUT"; exit 1; }
done

echo ">> [3] upstream sha"
if [ -z "$UPSTREAM_SHA" ]; then
  [ -d "$OUT/src/.git" ] || { echo "FATAL: no $OUT/src checkout and no --upstream-sha"; exit 1; }
  UPSTREAM_SHA="$(git -C "$OUT/src" rev-parse HEAD)"
fi

echo ">> [4] stage + xattr-free tar (E7 / spec §10)"
rm -rf "$DIST"; mkdir -p "$DIST/stage/$STEM"
cp -Rc "$APP" "$DIST/stage/$STEM/Emacs.app" 2>/dev/null || cp -Rp "$APP" "$DIST/stage/$STEM/Emacs.app"
(cd "$DIST/stage" && COPYFILE_DISABLE=1 tar --no-xattrs -czf "../$ASSET" "$STEM")

echo ">> [5] checksums ($CHECKSUMS, bare-basename entries)"
(cd "$DIST" && shasum -a 256 "$ASSET" > "$CHECKSUMS" && shasum -c "$CHECKSUMS")

echo ">> [6] self-verify: tar listing"
listing="$(tar -tzf "$DIST/$ASSET")"
echo "$listing" | grep -qv "^$STEM/" && { echo "FATAL: entry outside stem dir"; exit 1; }
for bin in "${BINS[@]}"; do
  echo "$listing" | grep -qx "$STEM/$bin" || { echo "FATAL: $bin missing from tarball"; exit 1; }
done

echo ">> [7] self-verify: extract transport smoke (E7-correct checks)"
T="$(mktemp -d)"
tar -xzf "$DIST/$ASSET" -C "$T"
"$T/$STEM/Emacs.app/Contents/MacOS/Emacs" --batch --eval '(princ (format "ok %s\n" emacs-version))'
codesign --verify --strict "$T/$STEM/Emacs.app/Contents/Frameworks/libgnutls.30.dylib"
codesign --verify --strict "$T/$STEM/Emacs.app/Contents/MacOS/bin/emacsclient"
xcount="$(find "$T" -exec xattr -l {} + 2>/dev/null | grep -c -E 'com\.apple\.(quarantine|cs\.)' || true)"
[ "$xcount" = "0" ] || { echo "FATAL: $xcount signature/quarantine xattrs survived the tar"; exit 1; }
rm -rf "$T" "$DIST/stage"

printf '%s\n' "$UPSTREAM_SHA" > "$DIST/upstream-sha.txt"
echo ">> package: PASS — $DIST/$ASSET + $CHECKSUMS (upstream $UPSTREAM_SHA)"
```

- [ ] **Step 2: gitignore + mise task**

`.gitignore`: append `dist/` if absent:

```bash
grep -qx 'dist/' .gitignore || echo 'dist/' >> .gitignore
```

`mise.toml` — add after `[tasks.relocate]`:

```toml
[tasks.package]
description = "Phase 4: package build/<v>/Emacs.app into dist/<v>/ (xattr-free tar + SHASUMS256.txt + self-verify); args: <version> <tag>"
run = "bash pipeline/package"
```

- [ ] **Step 3: Validate the happy path on the real artifact (also validates mise arg forwarding)**

```bash
chmod +x pipeline/package
mise run package master emacs-master-2026-06-11
ls dist/master
```

Expected: `>> package: PASS`, with `ok 32.0.50`, both codesign verifies silent-ok, and `dist/master/` containing `misemacs-emacs-master-2026-06-11-macos-arm64.tar.gz`, `SHASUMS256.txt`, `upstream-sha.txt`. If `mise run package master …` does NOT forward args (older mise), change the pregate line in Step 5 and this step to call `bash pipeline/package master emacs-master-2026-06-11` directly and note it in the commit message.

- [ ] **Step 4: Validate the failure path (layout check fires)**

```bash
cp -Rc build/master build/layout-negative
rm build/layout-negative/Emacs.app/Contents/MacOS/bin/ebrowse
bash pipeline/package layout-negative t; echo "exit=$?"
rm -rf build/layout-negative dist/layout-negative
```

Expected: last lines are `FATAL: missing/non-executable Emacs.app/Contents/MacOS/bin/ebrowse …` then `exit=1`.

- [ ] **Step 5: Append the sentinel package run to pregate**

`.pregate/macos.sh` — append after the `mise run cleanroom` line:

```sh
mise run package master pregate-smoke   # Phase 4: layout + packaging self-verify on the just-built app
```

- [ ] **Step 6: Commit**

```bash
git add pipeline/package mise.toml .gitignore .pregate/macos.sh
git commit -m "feat(phase4): pipeline/package — layout check, xattr-free tar, SHASUMS, local transport smoke (spec 4.4)"
```

## Task 6: `pipeline/publish` + `pipeline/promote` + mise tasks

> **Review deviation (2026-06-13):** as-committed `pipeline/publish` materializes the tag
> snapshot via `snap="$(snapshot)"` (command substitution) before feeding `release.names`,
> instead of `snapshot | … mix release.names` directly in the process substitution — proc-sub
> failure is invisible to `set -e`, so a failed `git ls-remote` (partial snapshot) could let
> `gh release create` silently adopt a dangling tag (P2) and ship a wrong-commit release. The
> publish completeness guard also checks ASSET+CHECKSUMS, and `pipeline/promote` cross-checks
> the `--tag` against the packaged `dist/<version>/<asset>` before writing the manifest.

**Files:**
- Create: `pipeline/publish`, `pipeline/promote`
- Modify: `mise.toml`

- [ ] **Step 1: Write `pipeline/publish`** (mode 0755)

```bash
#!/usr/bin/env bash
# pipeline/publish --repo <owner/repo> [--version master] [--channel <ch>] — compute the
# next tag (Core.Tag over a FRESH snapshot), package, create the GitHub release.
# ALWAYS --latest=false (P3/G1: GitHub steals the Latest marker by default; flipping
# latest is promote's explicit job). Collision (P1) => re-snapshot + recompute + re-package.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO=""; VERSION="master"; CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --channel) CHANNEL="${2:?}"; shift 2 ;;
    *) echo "FATAL: unknown arg $1"; exit 1 ;;
  esac
done
[ -n "$REPO" ] || { echo "FATAL: --repo is required (G8 — no default repo)"; exit 1; }
if [ "$REPO" = "djgoku/misemacs" ] && [ "${MISEMACS_PUBLISH_OK:-}" != "1" ]; then
  echo "FATAL: publishing to djgoku/misemacs requires MISEMACS_PUBLISH_OK=1 (G8 interlock)"; exit 1
fi
CHANNEL="${CHANNEL:-$VERSION}"   # v1: channel == version name for master (Manifest invariant)
DATE="$(date -u +%F)"

snapshot() {  # union of git tags (complete; strips peeled ^{} dups) and release names (draft-held names, P4)
  {
    git ls-remote --tags "https://github.com/$REPO" | awk '{print $2}' \
      | sed -e 's|^refs/tags/||' -e 's|\^{}$||'
    gh release list --repo "$REPO" --limit 1000 --json tagName --jq '.[].tagName'
  } | sort -u
}

for attempt in 1 2 3; do
  echo ">> [attempt $attempt] tag snapshot + names (snapshot mode)"
  TAG=""; ASSET=""; CHECKSUMS=""
  while IFS= read -r line; do
    case "$line" in
      tag=*)       TAG="${line#tag=}" ;;
      asset=*)     ASSET="${line#asset=}" ;;
      checksums=*) CHECKSUMS="${line#checksums=}" ;;
    esac
  done < <(snapshot | (cd "$HERE/orchestrator" && mise exec -- mix release.names \
             --channel "$CHANNEL" --date "$DATE" --os macos --arch arm64 --tags-file -))
  [ -n "$TAG" ] || { echo "FATAL: release.names produced no tag"; exit 1; }

  echo ">> package $VERSION as $TAG"
  bash "$HERE/pipeline/package" "$VERSION" "$TAG"
  UPSTREAM_SHA="$(cat "$HERE/dist/$VERSION/upstream-sha.txt")"

  echo ">> gh release create $TAG on $REPO (--latest=false, G1)"
  set +e
  err="$(gh release create "$TAG" --repo "$REPO" --title "$TAG" --latest=false \
          --notes "$CHANNEL @ $UPSTREAM_SHA" \
          "$HERE/dist/$VERSION/$ASSET" "$HERE/dist/$VERSION/$CHECKSUMS" 2>&1)"
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "$err"
    echo ">> publish: PASS — $TAG on $REPO (not latest; promote is a separate step)"
    exit 0
  elif printf '%s' "$err" | grep -q "already exists"; then
    echo ">> tag collision (P1): $err — recomputing"
    continue
  else
    echo "FATAL: gh release create failed: $err"
    echo "       (partial release? inspect with: gh release view $TAG --repo $REPO;"
    echo "        clean up with: gh release delete $TAG --repo $REPO --yes [--cleanup-tag])"
    exit 1
  fi
done
echo "FATAL: 3 tag collisions in a row — investigate the snapshot"; exit 1
```

- [ ] **Step 2: Write `pipeline/promote`** (mode 0755)

```bash
#!/usr/bin/env bash
# pipeline/promote --repo <owner/repo> --tag <tag> [--version master] — attach
# build-manifest.json (idempotent via --clobber, P6) then flip the Latest marker
# (atomic + reversible, P3). LAB-ONLY in Phase 4 (G2); the real repo's first promote
# is Phase 5's first kept release. Rerun-safe: just run it again after any failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO=""; TAG=""; VERSION="master"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:?}"; shift 2 ;;
    --tag)     TAG="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    *) echo "FATAL: unknown arg $1"; exit 1 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$TAG" ] || { echo "usage: pipeline/promote --repo <owner/repo> --tag <tag>"; exit 1; }
if [ "$REPO" = "djgoku/misemacs" ] && [ "${MISEMACS_PUBLISH_OK:-}" != "1" ]; then
  echo "FATAL: promoting on djgoku/misemacs requires MISEMACS_PUBLISH_OK=1 (G8 interlock)"; exit 1
fi
SHA_FILE="$HERE/dist/$VERSION/upstream-sha.txt"
[ -f "$SHA_FILE" ] || { echo "FATAL: $SHA_FILE missing — run pipeline/package (or publish) first"; exit 1; }

echo ">> [1] build-manifest.json via mix release.manifest (Core.Hash fingerprint)"
(cd "$HERE/orchestrator" && mise exec -- mix release.manifest \
  --version "$VERSION" --tag "$TAG" --upstream-sha "$(cat "$SHA_FILE")" \
  --root "$HERE" --out "$HERE/dist/$VERSION/build-manifest.json")

echo ">> [2] attach manifest (idempotent)"
gh release upload "$TAG" "$HERE/dist/$VERSION/build-manifest.json" --repo "$REPO" --clobber

echo ">> [3] flip Latest marker to $TAG"
gh release edit "$TAG" --repo "$REPO" --latest

echo ">> promote: PASS — $TAG is Latest on $REPO and carries build-manifest.json"
```

- [ ] **Step 3: mise tasks**

`mise.toml` — add after `[tasks.package]`:

```toml
[tasks.publish]
description = "Phase 4: create a GitHub release (--latest=false) with asset+SHASUMS; args: --repo <owner/repo> [--version v]"
run = "bash pipeline/publish"

[tasks.promote]
description = "Phase 4: attach build-manifest.json + flip Latest (lab-only until Phase 5); args: --repo <owner/repo> --tag <tag>"
run = "bash pipeline/promote"
```

- [ ] **Step 4: Validate the guard rails (no network mutation involved)**

```bash
chmod +x pipeline/publish pipeline/promote
bash pipeline/publish 2>&1 | tail -1                       # expect: FATAL --repo required, exit 1
bash pipeline/publish --repo djgoku/misemacs 2>&1 | tail -1 # expect: FATAL interlock, exit 1
bash pipeline/promote --repo djgoku/misemacs --tag t 2>&1 | tail -1 # expect: FATAL interlock, exit 1
```

Expected: all three print the FATAL line and exit 1.

- [ ] **Step 5: Commit**

```bash
git add pipeline/publish pipeline/promote mise.toml
git commit -m "feat(phase4): pipeline/publish (+.N retry, --latest=false) + pipeline/promote (manifest+latest flip) (spec 4.5-4.6)"
```

## Task 7: E2E script (`scripts/e2e-aqua-install.sh`, host + in-VM modes)

**Files:**
- Create: `scripts/e2e-aqua-install.sh`
- Modify: `mise.toml`

- [ ] **Step 1: Write the script** (mode 0755). Host mode wraps pregate `--cmd` (Phase-3 pattern; the tree — including this script — is piped into the VM):

```bash
#!/usr/bin/env bash
# scripts/e2e-aqua-install.sh <owner/repo> <tag> <registry-url>          (host mode)
# scripts/e2e-aqua-install.sh --in-vm <owner/repo> <tag> <registry-url>  (inside the VM)
# The §14 DoD check: a credential-free clean box installs the release exactly like a
# user (MISE_AQUA_REGISTRY_URL + mise use aqua:<repo>@<tag>) and the app runs; then the
# E7-correct integrity checks (per-Mach-O sentinels, zero quarantine — E1 invariant).
set -euo pipefail

if [ "${1:-}" != "--in-vm" ]; then
  REPO="${1:?usage: e2e-aqua-install.sh <owner/repo> <tag> <registry-url>}"
  TAG="${2:?missing tag}"
  URL="${3:?missing registry url}"
  exec pregate --macos --verbose --cmd "bash scripts/e2e-aqua-install.sh --in-vm '$REPO' '$TAG' '$URL'"
fi

shift
REPO="${1:?}"; TAG="${2:?}"; URL="${3:?}"
export MISE_AQUA_REGISTRY_URL="$URL"
export MISE_DATA_DIR; MISE_DATA_DIR="$(mktemp -d)"
export MISE_CACHE_DIR; MISE_CACHE_DIR="$(mktemp -d)"   # separate from DATA — both must be fresh (P8 gotcha)
export MISE_GLOBAL_CONFIG_FILE; MISE_GLOBAL_CONFIG_FILE="$(mktemp)"
export MISE_YES=1
cd "$(mktemp -d)"

echo ">> [1] mise use aqua:$REPO@$TAG   (registry: $URL)"
mise use "aqua:$REPO@$TAG"

echo ">> [2] --batch launch through mise (PATH from the registry files: entries)"
mise exec -- Emacs --batch --eval '(princ (format "E2E-BATCH-OK %s\n" emacs-version))'

echo ">> [3] GUI frame smoke (best-effort; VM session has a display per Phase 3)"
if mise exec -- Emacs -Q --eval '(run-with-timer 1 nil (lambda () (kill-emacs 0)))' 2>/dev/null; then
  echo "E2E-GUI-OK"
else
  echo "E2E-GUI-SKIPPED (no display) — batch is the hard gate"
fi

INSTALL="$(mise where "aqua:$REPO@$TAG")"
echo ">> [4] per-Mach-O sentinel signatures (E7: bundle-level verify is build-time-only)"
codesign --verify --strict "$INSTALL"/misemacs-*/Emacs.app/Contents/Frameworks/libgnutls.30.dylib
codesign --verify --strict "$INSTALL"/misemacs-*/Emacs.app/Contents/MacOS/bin/emacsclient
echo "E2E-EMBEDDED-SIGS-OK"

echo ">> [5] quarantine-free install (E1 invariant via aqua's Go extraction)"
qcount="$(find "$INSTALL" -exec xattr -l {} + 2>/dev/null | grep -c com.apple.quarantine || true)"
[ "$qcount" = "0" ] || { echo "FATAL: $qcount quarantine xattrs in the install tree"; exit 1; }
echo "E2E-NO-QUARANTINE"

echo ">> e2e: PASS — $REPO@$TAG installs and runs on a clean box"
```

- [ ] **Step 2: mise task**

`mise.toml` — add after `[tasks.promote]`:

```toml
[tasks.e2e]
description = "Phase 4 DoD: clean pregate-VM install via mise/aqua; args: <owner/repo> <tag> <registry-url>"
run = "bash scripts/e2e-aqua-install.sh"
```

- [ ] **Step 3: Syntax-check + commit** (real validation is the lab run, Task 8)

```bash
chmod +x scripts/e2e-aqua-install.sh
bash -n scripts/e2e-aqua-install.sh && echo syntax-ok
git add scripts/e2e-aqua-install.sh mise.toml
git commit -m "feat(phase4): clean-box aqua-install E2E script (pregate --cmd, spec 4.7)"
```

## Task 8: Lab dress rehearsal (publish → VM E2E → promote)

The lab repo `djgoku/misemacs-phase4-lab` (public — G7) still holds brainstorm-time test releases and a 2-file registry. Reset it, give it the 4-file registry, then rehearse with the REAL artifact. **All commands target the lab repo only.**

**Files:** none in this repo (lab-side state + validation-log evidence in Task 10).

- [ ] **Step 1: Reset the lab (delete brainstorm releases/tags + the draft)**

```bash
for t in emacs-master-2026.06.01 emacs-master-2026-06-02 emacs-master-2026-06-05; do
  gh release delete "$t" --repo djgoku/misemacs-phase4-lab --yes --cleanup-tag
done
draft_id="$(gh api repos/djgoku/misemacs-phase4-lab/releases --jq '.[] | select(.draft) | .id')"
[ -n "$draft_id" ] && gh api -X DELETE "repos/djgoku/misemacs-phase4-lab/releases/$draft_id"
gh api repos/djgoku/misemacs-phase4-lab/releases --jq length   # expect: 0
git ls-remote --tags https://github.com/djgoku/misemacs-phase4-lab | wc -l  # expect: 0
```

- [ ] **Step 2: Update the lab registry to the 4-file vendored shape (repo_name = lab)**

Run as ONE block from the worktree root:

```bash
WT="$(git rev-parse --show-toplevel)"
cd "$(mktemp -d)" && gh repo clone djgoku/misemacs-phase4-lab . -- -q
sed -e 's/^    repo_name: misemacs$/    repo_name: misemacs-phase4-lab/' \
    -e 's/Hermetically-built relocatable Emacs.app for macOS, via mise + conda-forge/THROWAWAY Phase-4 lab variant/' \
    "$WT/aqua/registry.yaml" > aqua/registry.yaml
git add aqua/registry.yaml
git -c commit.gpgsign=false commit -qm "lab: 4-file registry matching the vendored contract"
git push -q && cd "$WT"
```

(Heads-up: the in-repo vendored file says `repo_name: misemacs`; the sed swaps only that line + description. `git push` to the LAB is fine — the no-push rule is for this repo.)

- [ ] **Step 3: Publish the REAL artifact to the lab**

```bash
mise run publish --repo djgoku/misemacs-phase4-lab
gh release view "$(gh release list --repo djgoku/misemacs-phase4-lab --limit 1 --json tagName --jq '.[0].tagName')" \
  --repo djgoku/misemacs-phase4-lab --json tagName,isDraft,isPrerelease,assets \
  --jq '{tag:.tagName, assets:[.assets[].name]}'
gh api repos/djgoku/misemacs-phase4-lab/releases/latest --jq .tag_name 2>&1 || echo "no latest yet — correct (--latest=false on the only release)"
```

Expected: `publish: PASS — emacs-master-<today> …`; assets = the ~150 MB tarball + `SHASUMS256.txt`.
Record `LAB_TAG=emacs-master-<today>` for the next steps.

> **Superseded (see validation log §2, 2026-06-13):** this step originally expected
> `releases/latest` → 404 "proves G1". That expectation was WRONG — `GET /releases/latest`
> falls back to the most-recent published release when *none* is flagged `make_latest`, so the
> sole `--latest=false` release IS returned. The real G1 property is **incumbent preservation**
> (a newer `--latest=false` release does not steal an existing flagged latest), confirmed live
> on the lab and on the real repo (`@latest` stayed `emacs-master-2026.06.05` throughout Task 10).

- [ ] **Step 4: VM E2E against the lab (~25 min: VM boot + 150 MB download + checks)**

```bash
mise run e2e djgoku/misemacs-phase4-lab "$LAB_TAG" \
  https://raw.githubusercontent.com/djgoku/misemacs-phase4-lab/main/aqua/registry.yaml
```

Expected: pregate `macos PASS` with `E2E-BATCH-OK 32.0.50`, `E2E-EMBEDDED-SIGS-OK`, `E2E-NO-QUARANTINE`, ideally `E2E-GUI-OK`. Save the log output for Task 10. If raw.githubusercontent still serves the OLD lab registry (~5 min CDN TTL), wait and retry before debugging.

- [ ] **Step 5: Promote on the lab + verify the marker flip (P8, fresh caches)**

```bash
mise run promote --repo djgoku/misemacs-phase4-lab --tag "$LAB_TAG"
gh api repos/djgoku/misemacs-phase4-lab/releases/latest --jq .tag_name   # expect: $LAB_TAG
MISE_AQUA_REGISTRY_URL=https://raw.githubusercontent.com/djgoku/misemacs-phase4-lab/main/aqua/registry.yaml \
  MISE_DATA_DIR=$(mktemp -d) MISE_CACHE_DIR=$(mktemp -d) MISE_GLOBAL_CONFIG_FILE=$(mktemp) \
  mise latest aqua:djgoku/misemacs-phase4-lab                            # expect: $LAB_TAG
gh release download "$LAB_TAG" --repo djgoku/misemacs-phase4-lab --pattern build-manifest.json --output - | head -c 400; echo
```

Expected: both lookups print `$LAB_TAG`; the manifest JSON shows `"schema":1` and the version entry with `released_tag == $LAB_TAG`. The dress rehearsal is complete — every real-repo step now has a passed twin.

## Task 9: Full pregate run (build → relocate → package in one fresh VM)

Proves the integrated recipe including the new sentinel package step, before touching the real repo. (~20–30 min; the VM builds Emacs from scratch.)

> **Review deviation (2026-06-13):** the first full pregate run surfaced a pre-existing
> latent bug — `.pregate/common.sh` trusted only the repo-root `mise.toml`, so the fresh-VM
> build aborted at `pipeline/build-emacs` (`versions/master/mise.toml … not trusted`; the host
> had it trusted, masking the gap in earlier phases). Fixed in `common.sh` by also trusting
> each `versions/*/mise.toml` (glob → "add a version = data only" preserved). Disk held at
> ~94–95 % throughout both VM runs with no tart-clone truncation, clearing the KB caution.

- [ ] **Step 1: Run pregate**

```bash
pregate --macos --verbose
```

Expected: `macos PASS`; log shows the existing build/relocate/cleanroom output plus `>> package: PASS — …misemacs-pregate-smoke-macos-arm64.tar.gz`. If it fails in `mise run package`, debug the package stage (Task 5) — the build/relocate stages are unchanged from Phase 3.

## Task 10: Real-repo E2E — publish, validate, clean up (TWO USER GATES)

> **STOP — USER GATE A.** Do not run Step 1 until the user explicitly approves
> publishing to `djgoku/misemacs` in this session (standing constraint: every
> real-repo release/tag mutation needs in-the-moment approval). Show them:
> the tag that will be created (`emacs-master-<today>`), that it is
> `--latest=false` (legacy `emacs-master-2026.06.05` keeps `@latest`, P3/P8),
> and that Step 4 deletes it afterwards (G2).

- [ ] **Step 1 (after GATE A): Publish to the real repo**

```bash
MISEMACS_PUBLISH_OK=1 mise run publish --repo djgoku/misemacs
gh api repos/djgoku/misemacs/releases/latest --jq .tag_name   # expect STILL: emacs-master-2026.06.05
```

Record `REAL_TAG=emacs-master-<today>` (watch for a `.N` suffix if the old system also released today).

- [ ] **Step 2: VM E2E against the real repo via the REAL consumed registry URL (P7 — what users actually configure; the old file it serves has an identical contract)**

```bash
mise run e2e djgoku/misemacs "$REAL_TAG" \
  https://raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml
```

Expected: pregate `macos PASS` with `E2E-BATCH-OK`, `E2E-EMBEDDED-SIGS-OK`, `E2E-NO-QUARANTINE`. **This is the §14 DoD** — `mise use aqua:djgoku/misemacs@<tag>` installed and ran on a clean box. Save the full log lines for Step 5.

- [ ] **Step 3: Confirm zero user-visible drift while the release exists**

```bash
gh api repos/djgoku/misemacs/releases/latest --jq .tag_name   # expect: emacs-master-2026.06.05
```

> **STOP — USER GATE B.** Get explicit approval for the cleanup deletion
> (`gh release delete "$REAL_TAG" --repo djgoku/misemacs --yes --cleanup-tag`).
> If the E2E FAILED: still request this same cleanup, then debug on the lab.

- [ ] **Step 4 (after GATE B): Cleanup + verify the repo is byte-identical to before (G2/P12)**

```bash
MISEMACS_PUBLISH_OK=1 gh release delete "$REAL_TAG" --repo djgoku/misemacs --yes --cleanup-tag
git ls-remote --tags https://github.com/djgoku/misemacs | grep -c "$REAL_TAG" || echo "tag gone"
gh api repos/djgoku/misemacs/releases/latest --jq .tag_name   # expect: emacs-master-2026.06.05
gh release list --repo djgoku/misemacs --limit 5              # expect: legacy releases only
```

- [ ] **Step 5: Record the evidence in the validation log**

Append to `docs/superpowers/validation-log.md`, after the Phase 4 brainstorm section, filling in the actual outputs captured above:

```markdown
## 2026-06-XX — Phase 4 (implementation): lab rehearsal + real-repo E2E (the §14 DoD)

### 1. Lab dress rehearsal (djgoku/misemacs-phase4-lab, real 150 MB artifact)
- `mise run publish --repo djgoku/misemacs-phase4-lab` → `<LAB_TAG>` created
  `--latest=false`; assets = tarball + SHASUMS256.txt; `releases/latest` = 404
  with one release (G1 proven live).
- VM E2E (pregate --cmd, fresh tahoe VM): E2E-BATCH-OK <version>,
  E2E-EMBEDDED-SIGS-OK, E2E-NO-QUARANTINE, <GUI line>.
- `mise run promote` → build-manifest.json attached (schema 1, Core.Hash
  fingerprint), Latest flipped; fresh-cache `mise latest` resolved <LAB_TAG> (P8).

### 2. Real repo (both steps user-approved; G2 lifecycle)
- publish: <REAL_TAG> created --latest=false; releases/latest stayed
  emacs-master-2026.06.05 throughout.
- **E2E (DoD): PASS** — in a pristine VM, `mise use aqua:djgoku/misemacs@<REAL_TAG>`
  via the real consumed registry URL; E2E-BATCH-OK <version>,
  E2E-EMBEDDED-SIGS-OK, E2E-NO-QUARANTINE, <GUI line>.
- cleanup: `gh release delete --cleanup-tag` → tag + release gone; Latest still
  emacs-master-2026.06.05; release list = legacy only. Repo unchanged (G2).

### 3. pregate (fresh VM, full recipe)
- build → relocate → cleanroom → `package master pregate-smoke`: PASS.
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/validation-log.md
git commit -m "docs(phase4): lab rehearsal + real-repo E2E evidence — §14 DoD met, repo left unchanged (G2)"
```

## Task 11: Docs reconcile (umbrella spec + Naming canary)

**Files:**
- Modify: `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`
- Modify: `orchestrator/lib/orchestrator/naming.ex`, `orchestrator/test/orchestrator/naming_test.exs`

- [ ] **Step 1: Umbrella header + D6** — update the superseded fork-registry story (P7):

Replace the header line:
```markdown
- **Consumed by:** existing aqua registry `djgoku/aqua-registry@feat/djgoku/misemacs` → `mise use aqua:...`
```
with:
```markdown
- **Consumed by:** the vendored `aqua/registry.yaml` in this repo, served raw off `main` via `MISE_AQUA_REGISTRY_URL` → `mise use aqua:djgoku/misemacs@<tag>` (validated Phase 4, P7; the `djgoku/aqua-registry@feat/djgoku/misemacs` branch is a PR-shaped copy, not the consumed file)
```

In the D6 row, replace the rationale `Existing aqua registry already points here; zero registry edits` with `The consumed registry is aqua/registry.yaml in this repo (P7) — publishing here keeps one repo owning code, registry, and releases`.

- [ ] **Step 2: §7.2** — append to the "Self-healing fallback" list item:

```markdown
   *(Confirmed live, Phase 4 P10: legacy releases carry `build-manifest.org`,
   never `.json` — so the first automated run is the designed `first_run` case.)*
```

- [ ] **Step 3: §10** — after the "Xattrs" bullet, add:

```markdown
- **Vendored registry:** the consumed aqua registry is `aqua/registry.yaml` IN THIS
  REPO (users set `MISE_AQUA_REGISTRY_URL` to its raw-main URL — Phase 4, P7);
  `registry_contract_test.exs` binds it to `lib/naming`. Note: mise (2026.6.1)
  verifies GitHub's per-asset API digest, NOT `SHASUMS256.txt` (P9) — the file
  stays for the aqua contract + audit, and `pipeline/package` self-verifies it.
```

- [ ] **Step 4: §13** — in the **Validated** paragraph, append:

```markdown
**Phase 4 (publish/consumption, lab-proven P1–P14):** `gh release create` on an
existing release = exit 1 "already exists" (the `.N` retry signal); on a dangling
tag = silent adoption (snapshot must union tags ∪ release names); a create
WITHOUT `--latest=false` steals the Latest marker; drafts are tagless/invisible;
aqua `{{.Arch}}` = `arm64` (Naming canary closed); `@latest` = the GitHub
latest-release marker, not version sort; mise does not verify SHASUMS256.txt
(GitHub API digest instead); legacy releases carry no build-manifest.json ⇒
first run = `first_run`.
```

And delete these two now-resolved **Open** bullets: `Exact gh release create exit code on a pre-existing tag (confirm before Phase 4).` and the `--with-ns Info.plist/icon` line's trailing sentence `The final aqua extraction layout (the bin/ move) is Phase 4.` (replace that sentence with `The aqua extraction layout shipped/checked in Phase 4 (check-only — the build already emits it).`).

- [ ] **Step 5: §14 Phase-4 row** — replace the row's "Done = validated by" cell with:

```markdown
**DONE:** `mise use aqua:djgoku/misemacs@<tag>` installed & ran in a pristine VM via the real registry URL (validation log Phase 4); per G2 the validated release was then removed (`--cleanup-tag`) — the first KEPT release ships with Phase 5 automation; `package`/`publish`/`promote` + `release.names`/`release.manifest` are the Phase-5 primitives |
```

- [ ] **Step 6: Naming canary** — in `orchestrator/lib/orchestrator/naming.ex`, replace the bracketed OPEN sentence in the `ARCH NOTE` with:

```elixir
  ARCH NOTE: the registry has NO arch replacement, so the `arch` passed in MUST equal the
  token aqua renders for the platform ({{.Arch}}). VALIDATED (Phase 4, P7): a real
  `mise install` resolved `…-macos-arm64.tar.gz` on darwin/arm64 — aqua renders `arm64`.
```

In `orchestrator/test/orchestrator/naming_test.exs`, replace the canary comment inside `"arch token passes through verbatim …"`:

```elixir
    # Validated Phase 4 (P7): aqua's {{.Arch}} on darwin/arm64 IS "arm64" (real install).
    # This stays as the canary in case aqua ever changes its normalization.
```

- [ ] **Step 7: Test + commit**

```bash
mise run test && mise run lint
git add docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md \
        orchestrator/lib/orchestrator/naming.ex orchestrator/test/orchestrator/naming_test.exs
git commit -m "docs(phase4): reconcile umbrella spec (header/D6/7.2/10/13/14) + close Naming arm64 canary (P7)"
```

## Task 12: Final verification + wrap-up

- [ ] **Step 1: Full suite + lint, clean tree**

```bash
mise run test    # expect: 75 tests (58 existing + 6 registry + 8 names + 3 manifest) — verify the real count, 0 failures
mise run lint
git status --porcelain   # expect: empty
```

- [ ] **Step 2: Spec DoD walk** — open `docs/superpowers/specs/2026-06-11-phase-4-package-publish-design.md` §9 and verify every checkbox is satisfiable with evidence from this branch; fix anything missed.

- [ ] **Step 3: Remind the user of the two post-merge actions** (cannot be done by Claude):
  - Delete `djgoku/misemacs-phase4-lab` (token lacks `delete_repo`) — G7.
  - Merging/pushing this branch is theirs (git workflow).

- [ ] **Step 4: Finish** — use superpowers:finishing-a-development-branch (present merge/PR options; user decides).

---

## Self-review notes (spec → plan coverage)

- Spec §4.1 → Task 2; §4.2 → Task 3; §4.3 → Task 4; §4.4 (incl. pregate step) → Task 5 (+ Task 9 runs it in the VM); §4.5 → Task 6; §4.6 → Task 6; §4.7/§4.8 → Task 7; §5 sequencing → Tasks 8–10 in order (local self-verify happens in Task 5 Step 3); §6 guard rails → Task 6 Step 4 validates them; §7 docs → Tasks 10/11; §9 DoD → Task 12 walk.
- The G8 cleanup command in Task 10 Step 4 sets `MISEMACS_PUBLISH_OK=1` for symmetry though `gh release delete` is invoked directly (the interlock lives in our scripts, not gh) — the GATE B approval is the real control there.
- Counts in Task 12 are written as "record the real number" deliberately: 58 existing + 6 (Task 2) + 8 (Task 3) + 3 (Task 4) = 75 expected; verify, don't assume.
