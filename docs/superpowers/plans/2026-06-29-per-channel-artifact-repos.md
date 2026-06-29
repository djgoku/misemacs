# Per-Channel Artifact Repos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish each Emacs channel (`master`, `emacs-31`, …) to its own write-only GitHub "artifact" repo (`djgoku/misemacs-emacs-<channel>`) from the single source repo, so mise's 100-item list cap can never starve a low-frequency channel.

**Architecture:** One source repo unchanged. CI's build matrix carries a derived `repo` per cell; `pipeline/publish` (already `--repo`-parameterized) targets the per-channel repo; a per-channel CI finalize matrix flips each repo's (now cosmetic) Latest + attaches that channel's `build-manifest.json` state. `decide` reads each channel's manifest from its own repo's **sort-newest tag** with a three-way `:ok`/`:empty`/`:error` result so a missing/auth-failed repo fails loudly instead of masquerading as a first run. `version_source: github_tag` is kept (orthogonal: it keeps `@latest` marker-independent). Cross-repo writes use a GitHub App token minted just-in-time.

**Tech Stack:** Elixir/Mix (pure-core + injectable-IO orchestrator), ExUnit, bash pipeline scripts, GitHub Actions, mise + aqua registry.

**Design spec:** `docs/superpowers/specs/2026-06-29-per-channel-artifact-repos-design.md` (decisions D1–D5).

**Conventions used by this plan:**
- Run all Elixir commands from the `orchestrator/` dir. Full suite: `cd orchestrator && mix test`.
- Artifact-repo name = `<base>-emacs-<channel>` where `base` defaults to `djgoku/misemacs` and is overridable **only** via env `MISEMACS_ARTIFACT_BASE` (one env name everywhere — bash, Elixir, CI). The Elixir helper takes `base` explicitly.
- Commits are signed (YubiKey) — each commit step will prompt once.

**Task order is load-bearing.** Dependency graph: Task 1 → {2, 3, 8}; Task 2 → {7, 10}; Task 3 → {6, 10}; Task 4 → 6; **Task 5 → {6, 7}**; {6, 7, 9} → 10; {8, 9, 10} → 11. Do them in numeric order.

---

## File structure (what changes)

| File | Responsibility | Tasks |
|---|---|---|
| `orchestrator/lib/orchestrator/naming.ex` | SOLE owner of name strings — add `artifact_repo/2` | 1 |
| `orchestrator/lib/orchestrator/manifest.ex` | `jobs/3` emits `repo`; `load/3` threads `base` | 2 |
| `orchestrator/lib/mix/tasks/release.manifest.ex` | fragment stamps `channel` + `repo` (channel derived) | 3 |
| `orchestrator/lib/orchestrator/core/latest.ex` | newest-by-sort (`Enum.max`) selection | 4 |
| `orchestrator/lib/orchestrator/releases.ex` | callback → three-way result | 5 |
| `orchestrator/lib/orchestrator/releases/gh.ex` | sort-newest read + `:ok`/`:empty`/`:error` | 5 |
| `orchestrator/lib/orchestrator/orchestrate.ex` | `finalize_outputs/3` filters by repo + max-select | 6 |
| `orchestrator/lib/mix/tasks/orchestrate.finalize.ex` | filter fragments to `--repo` | 6 |
| `orchestrator/lib/mix/tasks/orchestrate.decide.ex` | read N per-channel manifests + preflight | 7 |
| `aqua/registry.yaml` | repoint both packages, keep `github_tag` | 8 |
| `orchestrator/test/orchestrator/registry_contract_test.exs` | assert repos + `github_tag` | 8 |
| `pipeline/publish`, `pipeline/promote` | derived-name assertion | 9 |
| `.github/workflows/daily.yml` | App token JIT, `matrix.repo`, finalize matrix | 10 |
| `README.org` | per-repo packages + add-a-version flow | 11 |

---

## Task 1: `Naming.artifact_repo/2`

**Files:**
- Modify: `orchestrator/lib/orchestrator/naming.ex`
- Test: `orchestrator/test/orchestrator/naming_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `orchestrator/test/orchestrator/naming_test.exs` (before the final `end`):

```elixir
  test "artifact_repo composes <base>-emacs-<channel>" do
    assert Naming.artifact_repo("djgoku/misemacs", "master") == "djgoku/misemacs-emacs-master"
    assert Naming.artifact_repo("djgoku/misemacs", "31") == "djgoku/misemacs-emacs-31"
  end

  test "artifact_repo honors a custom base (lab)" do
    assert Naming.artifact_repo("djgoku/misemacs-lab", "master") ==
             "djgoku/misemacs-lab-emacs-master"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/naming_test.exs`
Expected: FAIL — `function Orchestrator.Naming.artifact_repo/2 is undefined`

- [ ] **Step 3: Write minimal implementation**

In `orchestrator/lib/orchestrator/naming.ex`, add after the `tag_base/2` function:

```elixir
  @doc """
  Artifact repo for a channel: `<base>-emacs-<channel>` (e.g.
  `djgoku/misemacs-emacs-master`). `base` is the source-repo-shaped prefix; the lab
  passes its own (`djgoku/misemacs-lab`). SOLE owner of the channel→repo convention.
  """
  @spec artifact_repo(String.t(), String.t()) :: String.t()
  def artifact_repo(base, channel), do: "#{base}-emacs-#{channel}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd orchestrator && mix test test/orchestrator/naming_test.exs`
Expected: PASS (all naming tests green)

- [ ] **Step 5: Commit**

```bash
git add orchestrator/lib/orchestrator/naming.ex orchestrator/test/orchestrator/naming_test.exs
git commit -m "feat(orchestrator): Naming.artifact_repo/2 (channel->repo convention)"
```

---

## Task 2: `Manifest.jobs/3` emits `repo`

The matrix cell needs a `repo` field so `daily.yml` can pass `--repo "${{ matrix.repo }}"`. `jobs/2` becomes `jobs/3` taking the artifact `base`; `load/2` becomes `load/3`.

**Files:**
- Modify: `orchestrator/lib/orchestrator/manifest.ex:29-55`
- Modify: `orchestrator/lib/mix/tasks/orchestrate.decide.ex` (caller + base helper)
- Test: `orchestrator/test/orchestrator/manifest_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `orchestrator/test/orchestrator/manifest_test.exs` (inside the module, before the final `end`):

```elixir
  test "jobs/3 stamps the per-channel artifact repo onto every cell" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}
    targets = %{"macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-26", "enabled" => true}}

    [job] = Orchestrator.Manifest.jobs(versions, targets, "djgoku/misemacs")
    assert job.repo == "djgoku/misemacs-emacs-master"
    assert job.channel == "master"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/manifest_test.exs`
Expected: FAIL — `function Orchestrator.Manifest.jobs/3 is undefined`.

- [ ] **Step 3: Implement `jobs/3` + `load/3`**

In `orchestrator/lib/orchestrator/manifest.ex`, replace the `jobs/2` function (`:29-44`) with `jobs/3` adding `repo`, and `load/2` (`:46-55`) with `load/3` threading `base`:

```elixir
  def jobs(versions, targets, base) do
    enabled = for {tn, t} <- targets, Map.get(t, "enabled", false), do: {tn, t}

    for {vn, v} <- versions, {tn, t} <- enabled do
      %{
        name: vn,
        channel: v["channel"],
        ref: v["ref"],
        target: tn,
        os: t["os"],
        arch: t["arch"],
        runner: t["runner"],
        repo: Orchestrator.Naming.artifact_repo(base, v["channel"])
      }
    end
    |> Enum.sort_by(&{&1.name, &1.target})
  end

  @doc "Read + parse both TOML manifests into a job list (artifact `base` for repo derivation)."
  @spec load(Path.t(), Path.t(), String.t()) :: {:ok, [job()]} | {:error, term()}
  def load(versions_path, targets_path, base) do
    with {:ok, vbin} <- File.read(versions_path),
         {:ok, tbin} <- File.read(targets_path),
         {:ok, vmap} <- Toml.decode(vbin),
         {:ok, tmap} <- Toml.decode(tbin) do
      {:ok, jobs(Map.get(vmap, "versions", %{}), Map.get(tmap, "targets", %{}), base)}
    end
  end
```

Add `repo: String.t()` to the `@type job ::` map near `:14`.

- [ ] **Step 4: Update the `decide` caller**

In `orchestrator/lib/mix/tasks/orchestrate.decide.ex`, change the `Manifest.load(...)` call (`:38`) to:

```elixir
    {:ok, jobs} =
      Manifest.load(
        Path.join(root, "versions.toml"),
        Path.join(root, "targets.toml"),
        artifact_base(opts)
      )
```

Add this private helper at the bottom of the module (before the final `end`):

```elixir
  # Artifact-repo base: env override (lab/CI) else the SOURCE repo string itself
  # (djgoku/misemacs -> djgoku/misemacs-emacs-<channel>). Default keeps non-detect modes working.
  defp artifact_base(opts) do
    System.get_env("MISEMACS_ARTIFACT_BASE") || opts[:repo] || "djgoku/misemacs"
  end
```

- [ ] **Step 5: Fix all other `jobs/2`/`load/2` call sites**

Run: `cd orchestrator && mix compile 2>&1 | grep -i "jobs/2\|load/2" || echo "no stale arity refs"`
For every flagged site (and any test using `Manifest.load/2` or `jobs/2` directly), pass the base `"djgoku/misemacs"` to make it `/3`.

- [ ] **Step 6: Run tests**

Run: `cd orchestrator && mix test test/orchestrator/manifest_test.exs test/mix/tasks/orchestrate_decide_test.exs`
Expected: PASS.

- [ ] **Step 7: Full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add orchestrator/lib/orchestrator/manifest.ex orchestrator/lib/mix/tasks/orchestrate.decide.ex orchestrator/test/orchestrator/manifest_test.exs
git commit -m "feat(orchestrator): matrix cell carries per-channel repo (jobs/3 + base)"
```

---

## Task 3: Fragment stamps `channel` + `repo` (channel derived from `versions.toml`)

`finalize` groups fragments by artifact repo, so each fragment must carry its `channel` + `repo`. To avoid breaking existing callers (`pipeline/promote` calls `mix release.manifest` with no `--channel`), the channel is **derived from `versions.toml`** by version name (the task already reads that file for `ref`). Only a new **optional** `--artifact-base` flag (default env `MISEMACS_ARTIFACT_BASE`, then `djgoku/misemacs`) is added.

**Files:**
- Modify: `orchestrator/lib/mix/tasks/release.manifest.ex`
- Test: `orchestrator/test/mix/tasks/release_manifest_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `orchestrator/test/mix/tasks/release_manifest_test.exs` (uses a private tmp dir cleaned via `on_exit` — never `System.tmp_dir!()` itself):

```elixir
  test "fragment stamps channel (from versions.toml) and artifact repo at top level" do
    dir = Path.join(System.tmp_dir!(), "frag-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    out = Path.join(dir, "build-manifest.json")

    Mix.Tasks.Release.Manifest.run([
      "--version", "master",
      "--tag", "emacs-master-2026-06-29",
      "--upstream-sha", "deadbeef",
      "--out", out,
      "--root", "..",
      "--clt-fingerprint", "test-clt"
    ])

    m = out |> File.read!() |> JSON.decode!()
    assert m["channel"] == "master"
    assert m["repo"] == "djgoku/misemacs-emacs-master"
    assert m["versions"]["master"]["released_tag"] == "emacs-master-2026-06-29"
  end
```

(Match the existing tests' `--root ".."` + `--clt-fingerprint` conventions, already used to stay network-free.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/mix/tasks/release_manifest_test.exs`
Expected: FAIL — `m["channel"]` is nil.

- [ ] **Step 3: Implement**

In `orchestrator/lib/mix/tasks/release.manifest.ex`:

Add `Naming` to the alias: `alias Orchestrator.{Core.Hash, Manifest, Naming}`.

Add `artifact_base: :string` to `@switches` (do NOT add `channel`).

In `run/1`, after `version = required(opts, :version)`, add:

```elixir
    channel = channel_for!(root, version)
    base = opts[:artifact_base] || System.get_env("MISEMACS_ARTIFACT_BASE") || "djgoku/misemacs"
```

> Note: `root` is assigned a few lines below in the current code (`root = opts[:root] || ".."`). Move that `root = ...` line up so it precedes the `channel_for!(root, version)` call.

Change the `manifest = %{...}` map to add the two top-level keys:

```elixir
    manifest = %{
      "schema" => 1,
      "channel" => channel,
      "repo" => Naming.artifact_repo(base, channel),
      "versions" => %{
        version => %{
          "ref" => ref,
          "upstream_sha" => sha,
          "inputs_hash" => inputs_hash,
          "released_tag" => tag
        }
      }
    }
```

Add a `channel_for!/2` helper mirroring the existing `ref_for!/2`:

```elixir
  defp channel_for!(root, version) do
    with {:ok, map} <- Toml.decode(File.read!(Path.join(root, "versions.toml"))),
         %{"channel" => channel} <- get_in(map, ["versions", version]) do
      channel
    else
      _ -> Mix.raise("no channel for version #{inspect(version)} in versions.toml")
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd orchestrator && mix test test/mix/tasks/release_manifest_test.exs`
Expected: PASS (existing tests unaffected — they pass `--version` which now also yields a derived channel).

- [ ] **Step 5: Full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add orchestrator/lib/mix/tasks/release.manifest.ex orchestrator/test/mix/tasks/release_manifest_test.exs
git commit -m "feat(orchestrator): manifest fragment stamps channel + artifact repo"
```

---

## Task 4: `Core.Latest` — newest-by-sort

Resolution is `github_tag` (sort-based), and finalize runs per-repo (Tasks 6/10), so within one finalize the tags are all one channel. The latest tag is the **lexical max** (zero-padded ISO dates + `.N` collision suffixes sort newest), not recency-order `List.last`.

**Files:**
- Modify: `orchestrator/lib/orchestrator/core/latest.ex`
- Test: `orchestrator/test/orchestrator/core/latest_test.exs`

- [ ] **Step 1: Rewrite the test**

Replace the body of `orchestrator/test/orchestrator/core/latest_test.exs` with:

```elixir
defmodule Orchestrator.Core.LatestTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Latest

  test "nothing built => :unchanged" do
    assert Latest.latest_target([]) == :unchanged
  end

  test "a single build becomes latest" do
    assert Latest.latest_target(["emacs-master-2026-06-05"]) == {:set, "emacs-master-2026-06-05"}
  end

  test "newest is the lexical max regardless of input order" do
    tags = ["emacs-31-2026-06-28", "emacs-31-2026-06-29", "emacs-31-2026-06-27"]
    assert Latest.latest_target(tags) == {:set, "emacs-31-2026-06-29"}
  end

  test "a same-day .N collision suffix sorts newest" do
    tags = ["emacs-31-2026-06-29", "emacs-31-2026-06-29.1"]
    assert Latest.latest_target(tags) == {:set, "emacs-31-2026-06-29.1"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/core/latest_test.exs`
Expected: FAIL — unordered/`.N` cases return the wrong tag (current `List.last`).

- [ ] **Step 3: Implement**

Replace the function in `orchestrator/lib/orchestrator/core/latest.ex`:

```elixir
defmodule Orchestrator.Core.Latest do
  @moduledoc """
  Pure 'latest' selection. No IO.

  The newest tag is the lexical MAX of the built tags — zero-padded ISO dates sort
  chronologically and `.N` same-day collision suffixes sort newest, the same ordering
  aqua's `github_tag` resolution relies on. finalize is invoked per artifact repo
  (per channel), so the input is one channel's tags. `:unchanged` when nothing was built.
  """
  @spec latest_target([String.t()]) :: {:set, String.t()} | :unchanged
  def latest_target([]), do: :unchanged
  def latest_target(tags) when is_list(tags), do: {:set, Enum.max(tags)}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd orchestrator && mix test test/orchestrator/core/latest_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add orchestrator/lib/orchestrator/core/latest.ex orchestrator/test/orchestrator/core/latest_test.exs
git commit -m "feat(orchestrator): Core.Latest selects newest by sort (github_tag-aligned)"
```

---

## Task 5: `Releases` three-way + sort-newest read (newest tag authoritative)

`last_manifest/1` must (a) distinguish a reachable-but-empty repo (genuine first run) from an unreachable/auth-failed one (must fail loudly), and (b) read state from the **lexical-newest tag only** — if that newest tag has no/corrupt manifest, return `{:error, …}` (NO silent scan-back to older state). Split IO from a pure classifier so it's unit-testable. **This task precedes Tasks 6 and 7, which consume the three-way result.**

**Files:**
- Modify: `orchestrator/lib/orchestrator/releases.ex` (callback type)
- Modify: `orchestrator/lib/orchestrator/releases/gh.ex`
- Test: `orchestrator/test/orchestrator/releases_test.exs`

- [ ] **Step 1: Write the failing tests (pure classifier)**

Add to `orchestrator/test/orchestrator/releases_test.exs`:

```elixir
  test "classify: list failed => :error" do
    assert {:error, _} = Gh.classify({:error, :gh_failed}, fn _tag -> :unused end)
  end

  test "classify: reachable, no tags => :empty" do
    assert Gh.classify({:ok, []}, fn _tag -> raise "should not fetch" end) == :empty
  end

  test "classify: returns ONLY the lexical-newest tag's manifest" do
    fetched =
      fn
        "emacs-31-2026-06-29" -> %{"versions" => %{"emacs-31" => %{}}}
        other -> flunk("only the newest tag should be fetched, got #{other}")
      end

    assert {:ok, %{"versions" => _}} =
             Gh.classify({:ok, ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]}, fetched)
  end

  test "classify: newest tag lacks a manifest => :error (no scan-back to older state)" do
    assert {:error, _} =
             Gh.classify({:ok, ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]}, fn _ -> nil end)
  end
```

(`alias Orchestrator.Releases.Gh` is already at the top of this test file.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/releases_test.exs`
Expected: FAIL — `Gh.classify/2` undefined.

- [ ] **Step 3: Implement the pure classifier + rewire IO to tag listing**

In `orchestrator/lib/orchestrator/releases/gh.ex`, replace `last_manifest/1` and the `latest_tag/1`/`recent_tags/1` helpers (and delete the `@scan` attribute) with:

```elixir
  @impl true
  def last_manifest(repo) do
    classify(list_tags(repo), &fetch(repo, &1))
  end

  @doc """
  Pure decision over a `list_tags` result + a `fetch.(tag)` fun. ONLY the lexical-newest
  tag is authoritative (matches aqua's `github_tag` resolution; the per-channel repo holds
  one channel so the max is unambiguous):
    * `{:error, reason}`              -> `{:error, reason}` (repo unreachable/auth failure)
    * `{:ok, []}`                     -> `:empty` (reachable, no releases = first run)
    * `{:ok, tags}`, newest has mfst  -> `{:ok, manifest}`
    * `{:ok, tags}`, newest lacks it  -> `{:error, {:no_manifest_on_newest, tag}}`
  """
  @spec classify({:ok, [String.t()]} | {:error, term()}, (String.t() -> map() | nil)) ::
          {:ok, map()} | :empty | {:error, term()}
  def classify({:error, reason}, _fetch), do: {:error, reason}
  def classify({:ok, []}, _fetch), do: :empty

  def classify({:ok, tags}, fetch) do
    newest = Enum.max(tags)

    case fetch.(newest) do
      nil -> {:error, {:no_manifest_on_newest, newest}}
      manifest -> {:ok, manifest}
    end
  end

  # IO: list the repo's git tags (newest page). {:ok, [name]} on success (possibly empty),
  # {:error, _} on gh failure. The GitHub tags API returns the newest 100; the per-channel
  # repo's global-newest is therefore present and `classify` takes the lexical max.
  defp list_tags(repo) do
    case gh(["api", "repos/#{repo}/tags?per_page=100", "--jq", ".[].name"]) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
```

Keep the existing private `fetch/2`, `parse_manifest/*`, `trim_nil/1`, and `gh/1` functions as-is. Update the moduledoc to describe the three-way result + newest-tag-authoritative read.

- [ ] **Step 4: Update the behaviour callback type**

In `orchestrator/lib/orchestrator/releases.ex`:

```elixir
  @callback last_manifest(repo :: String.t()) :: {:ok, map()} | :empty | {:error, term()}
```

Update its moduledoc's "returns `nil`" wording to the three-way result.

- [ ] **Step 5: Run tests**

Run: `cd orchestrator && mix test test/orchestrator/releases_test.exs`
Expected: PASS (classifier + the existing `parse_manifest` tests).

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/releases.ex orchestrator/lib/orchestrator/releases/gh.ex orchestrator/test/orchestrator/releases_test.exs
git commit -m "feat(orchestrator): last_manifest three-way (:ok/:empty/:error), newest-tag authoritative"
```

---

## Task 6: per-repo `finalize` (filters fragments to its `--repo`)

`mix orchestrate.finalize --repo <channel-repo>` is invoked once per channel by the CI matrix (Task 10). It uses only the fragments belonging to that repo (the `repo` field from Task 3) and consumes the three-way `last_manifest` from Task 5.

**Files:**
- Modify: `orchestrator/lib/orchestrator/orchestrate.ex` (`finalize_outputs/3`)
- Modify: `orchestrator/lib/mix/tasks/orchestrate.finalize.ex`
- Test: `orchestrator/test/orchestrator/orchestrate_test.exs`, `orchestrator/test/mix/tasks/orchestrate_finalize_test.exs`

- [ ] **Step 1: Write the failing test (pure shaping)**

Add to `orchestrator/test/orchestrator/orchestrate_test.exs`:

```elixir
  test "finalize_outputs keeps only this repo's fragments and picks its newest tag" do
    repo = "djgoku/misemacs-emacs-31"

    frags = [
      %{"repo" => repo, "versions" => %{"emacs-31" => %{"released_tag" => "emacs-31-2026-06-28"}}},
      %{"repo" => repo, "versions" => %{"emacs-31" => %{"released_tag" => "emacs-31-2026-06-29"}}},
      %{"repo" => "djgoku/misemacs-emacs-master",
        "versions" => %{"master" => %{"released_tag" => "emacs-master-2026-06-29"}}}
    ]

    out = Orchestrator.Orchestrate.finalize_outputs(nil, frags, repo)

    assert out.latest_tag == "emacs-31-2026-06-29"
    assert Map.keys(out.manifest["versions"]) == ["emacs-31"]
    assert out.built_tags == ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs`
Expected: FAIL — `finalize_outputs/3`'s 3rd arg is currently `built_tags` (a list), not a repo string.

- [ ] **Step 3: Implement `finalize_outputs/3` (repo-scoped)**

Replace `finalize_outputs/3` in `orchestrator/lib/orchestrator/orchestrate.ex`:

```elixir
  @doc """
  Finalize ONE artifact repo: keep only fragments whose `"repo"` == `repo`, merge them
  into `prior` (that channel's prior manifest), and pick the newest released tag.
  Returns `built_tags` (this repo's released tags, ascending) for the manifest-attach loop.
  """
  @spec finalize_outputs(map() | nil, [map()], String.t()) :: %{
          manifest: map(),
          latest_tag: String.t() | nil,
          built_tags: [String.t()]
        }
  def finalize_outputs(prior, fragments, repo) do
    mine = Enum.filter(fragments, &(Map.get(&1, "repo") == repo))

    tags =
      for f <- mine, {_v, e} <- Map.get(f, "versions", %{}), do: e["released_tag"]

    tags = tags |> Enum.reject(&is_nil/1) |> Enum.sort()

    latest =
      case Latest.latest_target(tags) do
        {:set, tag} -> tag
        :unchanged -> nil
      end

    %{manifest: Manifest.merge(prior, mine), latest_tag: latest, built_tags: tags}
  end
```

- [ ] **Step 4: Update the finalize task to the three-way + new shape**

In `orchestrator/lib/mix/tasks/orchestrate.finalize.ex`, replace `exec/2` and delete the old private `built_tags/1` helper:

```elixir
  def exec(opts, deps \\ default_deps()) do
    fragments = read_fragments(opts[:fragments] || ".")
    repo = opts[:repo]

    prior =
      case deps.releases.(repo) do
        {:ok, manifest} -> manifest
        :empty -> nil
        {:error, reason} ->
          Mix.raise("finalize: cannot read prior manifest for #{repo}: #{inspect(reason)}")
      end

    Orchestrate.finalize_outputs(prior, fragments, repo)
  end
```

Confirm `emit/2` pattern-matches `%{manifest: manifest, latest_tag: tag, built_tags: tags}` (it already prints `latest_tag=`/`built_tags=`); `finalize_outputs` now returns `built_tags`, so the previous `Map.put(:built_tags, tags)` wrapper in `exec` is gone.

- [ ] **Step 5: Update the finalize task test**

In `orchestrator/test/mix/tasks/orchestrate_finalize_test.exs`: make fixture fragments include a `"repo"` key matching the `--repo` under test, and change the stub `deps.releases` to return `{:ok, manifest}` or `:empty` (not a bare map / `nil`). Run:

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs test/mix/tasks/orchestrate_finalize_test.exs`
Expected: PASS

- [ ] **Step 6: Full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add orchestrator/lib/orchestrator/orchestrate.ex orchestrator/lib/mix/tasks/orchestrate.finalize.ex orchestrator/test/orchestrator/orchestrate_test.exs orchestrator/test/mix/tasks/orchestrate_finalize_test.exs
git commit -m "feat(orchestrator): per-repo finalize (filter fragments by repo, newest tag, three-way prior)"
```

---

## Task 7: `decide` reads N per-channel manifests + preflight

In detect mode, `decide` reads each channel's manifest from its own artifact repo, **fails the run** on `:error`, treats `:empty` as first-run, and merges the `:ok` ones into the single combined manifest `decide_outputs` already consumes.

**Files:**
- Modify: `orchestrator/lib/mix/tasks/orchestrate.decide.ex` (`exec/2` + helper)
- Test: `orchestrator/test/mix/tasks/orchestrate_decide_test.exs`

> The real `versions.toml` read via `root: ".."` contains BOTH `master` and `emacs-31`. `Manifest.versions!/1` sorts by name, so `emacs-31` (channel `"31"`) is read first. Stubs MUST cover **both** artifact repos: `djgoku/misemacs-emacs-31` and `djgoku/misemacs-emacs-master`.

- [ ] **Step 1: Write the failing tests**

Add to `orchestrator/test/mix/tasks/orchestrate_decide_test.exs` (adapt the `deps` map keys to the file's existing stub shape — it already injects `:upstream`, `:toolchain`, `:releases`):

```elixir
  test "detect: :error from a channel repo aborts the run" do
    deps = %{
      upstream: fn _v -> "sha" end,
      toolchain: fn -> "test-clt" end,
      releases: fn
        "djgoku/misemacs-emacs-31" -> {:error, :unauthorized}
        "djgoku/misemacs-emacs-master" -> :empty
        other -> flunk("unexpected repo #{other}")
      end
    }

    assert_raise Mix.Error, ~r/unauthorized/, fn ->
      Mix.Tasks.Orchestrate.Decide.exec(
        %{repo: "djgoku/misemacs", date: "2026-06-29", mode: "detect", root: ".."},
        deps
      )
    end
  end

  test "detect: all channels :empty => every version is first-run (builds)" do
    deps = %{
      upstream: fn _v -> "newsha" end,
      toolchain: fn -> "test-clt" end,
      releases: fn _repo -> :empty end
    }

    out =
      Mix.Tasks.Orchestrate.Decide.exec(
        %{repo: "djgoku/misemacs", date: "2026-06-29", mode: "detect", root: ".."},
        deps
      )

    assert out.any == true
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_decide_test.exs`
Expected: FAIL — `exec` calls `deps.releases` once for the source repo, doesn't iterate channels, doesn't raise on `:error`.

- [ ] **Step 3: Implement the per-channel read in `exec`**

In `orchestrator/lib/mix/tasks/orchestrate.decide.ex`, replace the detect branch:

```elixir
    {states, manifest} =
      if mode == "detect" do
        clt = deps.toolchain.()
        {current_states(versions, root, clt, deps.upstream),
         combined_manifest(versions, artifact_base(opts), deps.releases)}
      else
        {%{}, nil}
      end
```

Add this helper (alongside `artifact_base/1` from Task 2):

```elixir
  # Read each DISTINCT channel's manifest from its artifact repo; merge :ok ones'
  # "versions" maps into one combined manifest (the shape Decide.plan consumes via
  # previous_state). :empty -> no entry (first run for that channel). :error -> abort.
  defp combined_manifest(versions, base, read) do
    versions
    |> Enum.map(& &1.channel)
    |> Enum.uniq()
    |> Enum.reduce(%{"schema" => 1, "versions" => %{}}, fn channel, acc ->
      repo = Orchestrator.Naming.artifact_repo(base, channel)

      case read.(repo) do
        {:ok, %{"versions" => v}} -> update_in(acc, ["versions"], &Map.merge(&1, v))
        :empty -> acc
        {:error, reason} -> Mix.raise("decide preflight: #{repo} unreadable: #{inspect(reason)}")
      end
    end)
    |> case do
      %{"versions" => v} when map_size(v) == 0 -> nil
      combined -> combined
    end
  end
```

- [ ] **Step 4: Update any pre-existing detect test stubs**

The file's older detect tests stub `releases` returning a bare manifest map or `nil`. Change those: a bare manifest → `{:ok, manifest}`; a `nil` → `:empty`. Re-run:

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_decide_test.exs`
Expected: PASS

- [ ] **Step 5: Full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add orchestrator/lib/mix/tasks/orchestrate.decide.ex orchestrator/test/mix/tasks/orchestrate_decide_test.exs
git commit -m "feat(orchestrator): decide reads per-channel manifests + preflight aborts on :error"
```

---

## Task 8: Registry repoint (keep `github_tag`) + contract test

Point each aqua package at its artifact repo and **add** `version_source: github_tag` (kept per D5). The contract test is **string-based** (the existing test deliberately uses no YAML dependency — keep that style).

**Files:**
- Modify: `aqua/registry.yaml`
- Test: `orchestrator/test/orchestrator/registry_contract_test.exs`

- [ ] **Step 1: Re-read the existing contract test's style**

Run: `cat orchestrator/test/orchestrator/registry_contract_test.exs`
Confirm it reads the file as a string (e.g. `File.read!("../aqua/registry.yaml")`) and asserts with `=~`/substring checks — **do not** introduce `YamlElixir` (not a dep in `mix.exs`).

- [ ] **Step 2: Write the failing assertions (string style)**

Add to `orchestrator/test/orchestrator/registry_contract_test.exs` (reuse the file's existing `File.read!` of the registry; if it binds it to a var like `yaml`, reuse that):

```elixir
  test "each package points at its per-channel artifact repo" do
    yaml = File.read!(Path.expand("../aqua/registry.yaml", __DIR__) |> String.replace("/test/orchestrator", ""))
    assert yaml =~ "repo_name: misemacs-emacs-master"
    assert yaml =~ "repo_name: misemacs-emacs-31"
    refute yaml =~ ~r/repo_name:\s*misemacs\b(?!-)/
  end

  test "both packages keep version_source: github_tag" do
    yaml = File.read!(Path.expand("../aqua/registry.yaml", __DIR__) |> String.replace("/test/orchestrator", ""))
    assert length(Regex.scan(~r/version_source:\s*github_tag/, yaml)) == 2
  end
```

> Use the SAME path expression the existing tests in this file already use to locate `aqua/registry.yaml` (copy it verbatim rather than the `Path.expand` shown above if the file already has a helper/constant for it).

- [ ] **Step 3: Run to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/registry_contract_test.exs`
Expected: FAIL — `repo_name` is still `misemacs`; no `version_source`.

- [ ] **Step 4: Edit `aqua/registry.yaml`**

For `djgoku/misemacs-emacs-master`: change `repo_name: misemacs` → `repo_name: misemacs-emacs-master` and add `version_source: github_tag` right after the `name:` line. Same for `djgoku/misemacs-emacs-31` (→ `repo_name: misemacs-emacs-31`). `repo_owner` stays `djgoku`. Leave `type`, `version_prefix`, `asset`, `format`, `checksum`, `overrides`, `replacements` unchanged. Master shown:

```yaml
  - type: github_release
    name: djgoku/misemacs-emacs-master
    version_source: github_tag
    repo_owner: djgoku
    repo_name: misemacs-emacs-master
    description: Hermetically-built relocatable Emacs.app for macOS — master channel
    version_prefix: "emacs-master-"
    asset: misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz
    # ... unchanged below ...
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd orchestrator && mix test test/orchestrator/registry_contract_test.exs`
Expected: PASS

- [ ] **Step 6: Full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add aqua/registry.yaml orchestrator/test/orchestrator/registry_contract_test.exs
git commit -m "feat(registry): repoint packages to per-channel repos; keep version_source github_tag"
```

---

## Task 9: `publish`/`promote` derived-name assertion

A cheap data-validation guard (NOT the declined D2 env interlock): refuse to publish/promote unless `--repo` equals the channel's derived artifact repo. Catches a malformed matrix cell before any `gh release create`.

**Files:**
- Modify: `pipeline/publish`
- Modify: `pipeline/promote`

- [ ] **Step 1: Add the assertion to `pipeline/publish`**

In `pipeline/publish`, after the `CHANNEL="${CHANNEL:-$VERSION}"` block (~line 21) and before `DATE=...`, insert:

```bash
# Derived-name assertion (data validation, NOT an auth gate — spec D2/§4.5): the target
# repo MUST be this channel's artifact repo. Catches a bad/empty matrix.repo before any gh write.
EXPECTED_REPO="${MISEMACS_ARTIFACT_BASE:-djgoku/misemacs}-emacs-$CHANNEL"
if [ "$REPO" != "$EXPECTED_REPO" ]; then
  echo "FATAL: --repo '$REPO' != expected artifact repo '$EXPECTED_REPO' for channel '$CHANNEL'"; exit 1
fi
```

- [ ] **Step 2: Verify the publish guard rejects a mismatch before any network call**

Run:
```bash
MISEMACS_ARTIFACT_BASE=djgoku/misemacs bash pipeline/publish --repo djgoku/wrong --version master --channel master
```
Expected: prints `FATAL: --repo 'djgoku/wrong' != expected artifact repo 'djgoku/misemacs-emacs-master' for channel 'master'`, exits non-zero, **before** any `git ls-remote`/`gh`.

- [ ] **Step 3: Add the assertion to `pipeline/promote`**

`promote` gets `--tag` but not `--channel`; derive the channel from the tag. After the usage check (~line 22), insert:

```bash
# Derive channel from the tag (emacs-<channel>-YYYY-MM-DD[.N]) and assert the repo.
CH="$(printf '%s' "$TAG" | sed -E 's/^emacs-(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$/\1/')"
EXPECTED_REPO="${MISEMACS_ARTIFACT_BASE:-djgoku/misemacs}-emacs-$CH"
if [ "$CH" = "$TAG" ] || [ "$REPO" != "$EXPECTED_REPO" ]; then
  echo "FATAL: promote --repo '$REPO' / --tag '$TAG' — expected repo '$EXPECTED_REPO' (channel '$CH')"; exit 1
fi
```

- [ ] **Step 4: Verify the promote guard + happy-path channel parse**

Run:
```bash
MISEMACS_ARTIFACT_BASE=djgoku/misemacs bash pipeline/promote --repo djgoku/wrong --tag emacs-31-2026-06-29
printf 'emacs-master-2026-06-29.2' | sed -E 's/^emacs-(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$/\1/'
```
Expected: first command exits non-zero with `expected repo 'djgoku/misemacs-emacs-31' (channel '31')`; second prints `master`.

- [ ] **Step 5: Commit**

```bash
git add pipeline/publish pipeline/promote
git commit -m "feat(pipeline): assert --repo matches the channel's artifact repo (data validation)"
```

---

## Task 10: `daily.yml` — App token JIT, `matrix.repo`, per-channel finalize matrix

CI wiring. Not unit-testable; verify via diff + a dry-run PR. Everything keys off the single env `MISEMACS_ARTIFACT_BASE`.

Prereqs (one-time, manual — see Task 11 checklist): create `djgoku/misemacs-emacs-master` + `djgoku/misemacs-emacs-31`; create a GitHub App with **contents: write**, install it on both repos; add secrets `MISEMACS_APP_ID` + `MISEMACS_APP_PRIVATE_KEY`.

- [ ] **Step 0: Verify the App-token action version before wiring**

Run: `gh release view --repo actions/create-github-app-token --json tagName,publishedAt`
Use the current major tag (Codex flagged the plan's `@v2` may be stale; upstream may be `@v3` with a `client-id` input). Use whichever inputs the current release documents — `app-id` + `private-key`, or `client-id` + `private-key`. The snippets below assume `app-id`; adjust if the current release requires `client-id`.

- [ ] **Step 1: Add the workflow-level env**

In `daily.yml`'s top-level `env:` (create the block if absent), add:

```yaml
env:
  MISEMACS_ARTIFACT_BASE: djgoku/misemacs
```

This reaches every job/step: `decide` (so `jobs/3` derives `matrix.repo`), the build job's `release.manifest` (so the fragment's `repo` is correct), and the bash guards.

- [ ] **Step 2: Mint the App token just before publish, scoped to the channel's repo**

In the `build` job, immediately BEFORE the `publish (real) ...` step:

```yaml
      - name: mint publish token (App, just-in-time)
        if: needs.decide.outputs.dry_run != 'true'
        id: pubtoken
        uses: actions/create-github-app-token@v2   # confirm major in Step 0
        with:
          app-id: ${{ secrets.MISEMACS_APP_ID }}
          private-key: ${{ secrets.MISEMACS_APP_PRIVATE_KEY }}
          owner: djgoku
          repositories: ${{ format('misemacs-emacs-{0}', matrix.channel) }}
```

Then update the `publish (real) or package+artifact (dry-run)` step to use the minted token and `matrix.repo`:

```yaml
      - name: publish (real) or package+artifact (dry-run)
        env:
          GH_TOKEN: ${{ steps.pubtoken.outputs.token || github.token }}
        run: |
          set -euo pipefail
          if [ "${{ needs.decide.outputs.dry_run }}" = "true" ]; then
            TAG="$(cd orchestrator && mise exec -- mix release.names \
              --channel '${{ matrix.channel }}' --date "$(date -u +%F)" \
              --os '${{ matrix.os }}' --arch '${{ matrix.arch }}' --tags-file /dev/null \
              | sed -n 's/^tag=//p')"
            mise run package "${{ matrix.name }}" "$TAG"
          else
            mise run publish -- --repo "${{ matrix.repo }}" --version "${{ matrix.name }}" --channel "${{ matrix.channel }}"
          fi
```

> The `manifest fragment` step's `mix release.manifest` call needs **no new flags** — it derives `channel` from `versions.toml` and reads the base from the workflow `MISEMACS_ARTIFACT_BASE` env (Task 3). Leave that step's args unchanged.

- [ ] **Step 3: Emit the per-channel list from `decide`**

In the `decide` step script, after the existing `grep -E '^(matrix|any|dry_run)=' /tmp/decide.out >> "$GITHUB_OUTPUT"` line, add:

```bash
          # Distinct {channel,repo} built this run, for the finalize matrix.
          MATRIX="$(sed -n 's/^matrix=//p' /tmp/decide.out)"
          CHANNELS="$(printf '%s' "$MATRIX" | jq -c '[.include[] | {channel, repo}] | unique')"
          echo "channels=$CHANNELS" >> "$GITHUB_OUTPUT"
```

Add `channels: ${{ steps.decide.outputs.channels }}` to the `decide` job's `outputs:` block (beside `matrix`/`any`/`dry_run`).

> `jq` is available on GitHub-hosted `macos`/`ubuntu` runners by default; the `decide` job already runs on a hosted runner. Confirm in the dry-run (Step 5).

- [ ] **Step 4: Convert `finalize` to a per-channel matrix**

Replace the single `finalize` job with a matrix over `decide.outputs.channels`:

```yaml
  finalize:
    needs: [decide, build]
    if: ${{ !cancelled() && needs.decide.outputs.dry_run != 'true' && needs.decide.outputs.any == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJSON(needs.decide.outputs.channels) }}
    concurrency:
      group: finalize-${{ matrix.repo }}
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v6
      - uses: jdx/mise-action@v4
        with:
          version: 2026.6.6
          install: false
      - run: |
          mise install
          (cd orchestrator && mise exec -- mix deps.get)
      - uses: actions/download-artifact@v8
        with:
          path: fragments
          pattern: manifest-*
      - name: mint finalize token (App, just-in-time)
        id: fintoken
        uses: actions/create-github-app-token@v2   # confirm major in Step 0
        with:
          app-id: ${{ secrets.MISEMACS_APP_ID }}
          private-key: ${{ secrets.MISEMACS_APP_PRIVATE_KEY }}
          owner: djgoku
          repositories: ${{ format('misemacs-emacs-{0}', matrix.channel) }}
      - name: finalize + promote this channel
        env:
          GH_TOKEN: ${{ steps.fintoken.outputs.token }}
        run: |
          set -euo pipefail
          FIN="$(mise run finalize -- \
            --repo "${{ matrix.repo }}" \
            --fragments "$GITHUB_WORKSPACE/fragments" \
            --out "$GITHUB_WORKSPACE/dist/build-manifest.json")"
          LATEST_TAG="$(printf '%s\n' "$FIN" | sed -n 's/^latest_tag=//p')"
          BUILT_TAGS="$(printf '%s\n' "$FIN" | sed -n 's/^built_tags=//p')"
          if [ -z "$LATEST_TAG" ]; then echo "no fragments for ${{ matrix.repo }}"; exit 0; fi
          bash pipeline/promote --repo "${{ matrix.repo }}" --tag "$LATEST_TAG" \
            --manifest "$GITHUB_WORKSPACE/dist/build-manifest.json" \
            --attach "$BUILT_TAGS"
```

`MISEMACS_ARTIFACT_BASE` is inherited from the workflow env (Step 1), so `pipeline/promote`'s guard resolves the same base. `mix orchestrate.finalize` filters fragments to `--repo` (Task 6), so downloading all `manifest-*` and pointing each cell at its own `--repo` is correct.

- [ ] **Step 5: Lint + dry-run validation**

Run (if installed): `actionlint .github/workflows/daily.yml` → no errors.
Then push the branch / open a PR to trigger the `pull_request` dry-run path. Confirm in the Actions run: `decide` emits a non-empty `channels=`; `build` runs in dry-run (no token minted — the `if` skips it — and it packages a tarball); `finalize` is skipped by its dry-run guard. Check `jq` resolved in `decide`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/daily.yml
git commit -m "ci(daily): per-channel publish+finalize via matrix.repo + just-in-time App token"
```

---

## Task 11: README + lab end-to-end validation

**Files:**
- Modify: `README.org`
- (No code; a manual lab validation checklist proves the DoD.)

- [ ] **Step 1: Update `README.org`**

Document: (a) each channel is its own aqua package in its own repo (`aqua:djgoku/misemacs-emacs-master`, `…-emacs-31`); (b) `@latest` rolls each channel independently and is marker-independent (`version_source: github_tag`); (c) a freshly-added channel has no installable version until its first daily build publishes; (d) adding a version = the spec §4.10 flow (`versions.toml` + `versions/<name>/` + registry entry + one-time `gh repo create` + App install). Keep the existing prose style.

- [ ] **Step 2: Lab bootstrap (throwaway, non-prod)**

```bash
gh repo create djgoku/misemacs-lab-emacs-master --public
gh repo create djgoku/misemacs-lab-emacs-31 --public
```
Install the GitHub App on both (or export a lab PAT as `GH_TOKEN` for the manual publish).

- [ ] **Step 3: Publish each channel to its lab repo**

With base set so the guards/derivations agree:
```bash
export MISEMACS_ARTIFACT_BASE=djgoku/misemacs-lab
mise run publish -- --repo djgoku/misemacs-lab-emacs-master --version master --channel master
mise run publish -- --repo djgoku/misemacs-lab-emacs-31 --version emacs-31 --channel 31
```
Expected: each release lands in its own lab repo; the derived-name assertion passes.

- [ ] **Step 4: Prove per-channel resolution + crowding immunity**

Point mise at a lab registry variant (its `repo_name`s = the lab repos) with a fresh cache:
```bash
MISE_AQUA_REGISTRIES=<raw-lab-registry-url> MISE_CACHE_DIR=$(mktemp -d) MISE_DATA_DIR=$(mktemp -d) \
  MISE_MINIMUM_RELEASE_AGE=0 mise ls-remote 'aqua:djgoku/misemacs-lab-emacs-master'
# repeat for ...-emacs-31
```
Expected: each resolves to its own newest release, independent of the other's volume.

- [ ] **Step 5: Prove marker-independence (failed-finalize simulation)**

Flip Latest to an OLDER release, then re-resolve `@latest` with a fresh cache:
```bash
gh release edit <old-tag> --repo djgoku/misemacs-lab-emacs-master --latest
MISE_AQUA_REGISTRIES=<raw-lab-registry-url> MISE_CACHE_DIR=$(mktemp -d) MISE_DATA_DIR=$(mktemp -d) \
  MISE_MINIMUM_RELEASE_AGE=0 mise latest 'aqua:djgoku/misemacs-lab-emacs-master@latest'
```
Expected: resolves to the NEWEST tag, not the stale marker — confirming `github_tag` keeps `@latest` correct even when promote fails to flip Latest.

- [ ] **Step 6: Record validated facts in the knowledge base**

Append to `~/.claude/knowledge-base/mise.md` (with the lab commands as proof): per-channel repos remove the 100-item cross-channel crowding; `github_tag` `@latest` ignores a stale Latest marker on a real per-channel repo. Refresh the index pointer.

- [ ] **Step 7: Lab teardown + commit the README**

```bash
gh repo delete djgoku/misemacs-lab-emacs-master --yes
gh repo delete djgoku/misemacs-lab-emacs-31 --yes
git add README.org
git commit -m "docs(readme): per-channel artifact repos — packages, @latest, add-a-version"
```

---

## Definition of Done (from the spec §5)

- [ ] `Naming.artifact_repo/2` with tests (Task 1).
- [ ] `aqua/registry.yaml` both packages point at artifact repos and retain `version_source: github_tag`; contract test asserts both, string-style (Task 8).
- [ ] `Manifest.jobs/3` emits `repo`; `daily.yml` publish + per-channel finalize use `matrix.repo`; App token minted just before publish and before promote (Tasks 2, 10).
- [ ] `publish`/`promote` assert `--repo == <base>-emacs-<channel>` with negative checks (Task 9).
- [ ] Fragments carry `channel` (derived) + `repo`; `finalize` filters by repo; `Core.Latest` selects newest by sort, unit-tested for single/multi/`.N` (Tasks 3, 4, 6).
- [ ] `last_manifest/1` lists tags + returns `:ok`/`:empty`/`:error` with the **newest tag authoritative**; `decide` preflight fails loudly on `:error`, treats `:empty` as first-run (Tasks 5, 7).
- [ ] `cd orchestrator && mix test` green across the updated decide/finalize/manifest/releases/registry-contract tests.
- [ ] Lab check: per-channel `@latest` resolves independently; stale-marker simulation still resolves newest tag (Task 11).
- [ ] README updated (Task 11).
```
