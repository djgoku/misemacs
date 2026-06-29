# Per-Channel Artifact Repos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish each Emacs channel (`master`, `emacs-31`, …) to its own write-only GitHub "artifact" repo (`djgoku/misemacs-emacs-<channel>`) from the single source repo, so mise's 100-item list cap can never starve a low-frequency channel.

**Architecture:** One source repo unchanged. CI's build matrix carries a derived `repo` per cell; `pipeline/publish` (already `--repo`-parameterized) targets the per-channel repo; a per-channel CI finalize matrix flips each repo's (now cosmetic) Latest + attaches that channel's `build-manifest.json` state. `decide` reads each channel's manifest from its own repo with a three-way `:ok`/`:empty`/`:error` result so a missing/auth-failed repo fails loudly instead of masquerading as a first run. `version_source: github_tag` is kept (orthogonal: it keeps `@latest` marker-independent). Cross-repo writes use a GitHub App token minted just-in-time.

**Tech Stack:** Elixir/Mix (pure-core + injectable-IO orchestrator), ExUnit, bash pipeline scripts, GitHub Actions, mise + aqua registry.

**Design spec:** `docs/superpowers/specs/2026-06-29-per-channel-artifact-repos-design.md` (decisions D1–D5).

**Conventions used by this plan:**
- Run all Elixir commands from the `orchestrator/` dir. Full suite: `cd orchestrator && mix test`.
- Artifact-repo name = `<base>-emacs-<channel>` where `base` defaults to `djgoku/misemacs` and is overridable via env `MISEMACS_ARTIFACT_BASE` (used by the lab in Task 11). The Elixir helper takes `base` explicitly.
- Commits are signed (YubiKey) — each commit step will prompt once.

---

## File structure (what changes)

| File | Responsibility | Tasks |
|---|---|---|
| `orchestrator/lib/orchestrator/naming.ex` | SOLE owner of name strings — add `artifact_repo/2` | 1 |
| `orchestrator/lib/orchestrator/manifest.ex` | `jobs/3` emits `repo`; `load/3` threads `base` | 2 |
| `orchestrator/lib/mix/tasks/release.manifest.ex` | fragment stamps `channel` + `repo` | 3 |
| `orchestrator/lib/orchestrator/core/latest.ex` | newest-by-sort (`Enum.max`) selection | 4 |
| `orchestrator/lib/orchestrator/orchestrate.ex` | `finalize_outputs/3` filters by repo + max-select | 5 |
| `orchestrator/lib/mix/tasks/orchestrate.finalize.ex` | filter fragments to `--repo` | 5 |
| `orchestrator/lib/orchestrator/releases.ex` | callback → three-way result | 6 |
| `orchestrator/lib/orchestrator/releases/gh.ex` | sort-newest read + `:ok`/`:empty`/`:error` | 6 |
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
Expected: FAIL — `function Orchestrator.Manifest.jobs/3 is undefined` (and existing `jobs/2` callers still compile).

- [ ] **Step 3: Write minimal implementation**

In `orchestrator/lib/orchestrator/manifest.ex`, replace the `jobs/2` function (currently at `:29-44`) with a `jobs/3` that adds `repo`, and update `load/2` → `load/3` to thread `base`:

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

Also update the `@type job` typespec near `:14` to include `repo: String.t()` (find the existing `@type job ::` map and add the `repo` key).

- [ ] **Step 4: Update the caller in `decide`**

In `orchestrator/lib/mix/tasks/orchestrate.decide.ex`, find the `Manifest.load(...)` call (around `:38`) and change it to pass the artifact base. Add a helper to derive base from the source `--repo`'s owner (default `djgoku/misemacs`, env override). Replace the `Manifest.load` line:

```elixir
    {:ok, jobs} =
      Manifest.load(
        Path.join(root, "versions.toml"),
        Path.join(root, "targets.toml"),
        artifact_base(opts)
      )
```

And add this private helper at the bottom of the module (before the final `end`):

```elixir
  # Artifact-repo base: env override (lab) else the SOURCE repo string itself
  # (djgoku/misemacs -> djgoku/misemacs-emacs-<channel>). Default keeps prod working
  # if --repo is absent in non-detect modes.
  defp artifact_base(opts) do
    System.get_env("MISEMACS_ARTIFACT_BASE") || opts[:repo] || "djgoku/misemacs"
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd orchestrator && mix test test/orchestrator/manifest_test.exs test/mix/tasks/orchestrate_decide_test.exs`
Expected: PASS. If `orchestrate_decide_test.exs` constructs jobs via `Manifest.load/2` or `jobs/2` directly, update those call sites to the `/3` arity passing `"djgoku/misemacs"`.

- [ ] **Step 6: Run the full suite**

Run: `cd orchestrator && mix test`
Expected: PASS. Fix any remaining `jobs/2`/`load/2` call sites flagged by the compiler to the new arity.

- [ ] **Step 7: Commit**

```bash
git add orchestrator/lib/orchestrator/manifest.ex orchestrator/lib/mix/tasks/orchestrate.decide.ex orchestrator/test/orchestrator/manifest_test.exs
git commit -m "feat(orchestrator): matrix cell carries per-channel repo (jobs/3 + base)"
```

---

## Task 3: Fragment stamps `channel` + `repo`

`finalize` must group fragments by their artifact repo without re-parsing tag strings. Stamp the channel and repo into the manifest fragment at the top level (the `"versions"` map is unchanged so detection still works).

**Files:**
- Modify: `orchestrator/lib/mix/tasks/release.manifest.ex`
- Test: `orchestrator/test/mix/tasks/release_manifest_test.exs`

- [ ] **Step 1: Write the failing test**

Open `orchestrator/test/mix/tasks/release_manifest_test.exs`, find the test that runs the task and decodes the written JSON, and add assertions (or add a new test mirroring the existing invocation pattern). The fragment must now expose channel + repo. Add a `--channel` flag to the invocation in the test and assert:

```elixir
  test "fragment stamps channel and artifact repo at top level" do
    out = Path.join(System.tmp_dir!(), "frag-#{System.unique_integer([:positive])}.json")

    Mix.Tasks.Release.Manifest.run([
      "--version", "master",
      "--channel", "master",
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
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "."))
  end
```

(Match the existing test file's `--root`/`--clt-fingerprint` conventions; the existing tests already pass `--clt-fingerprint` to stay network-free.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/mix/tasks/release_manifest_test.exs`
Expected: FAIL — `--channel` is an unknown switch / `m["channel"]` is nil.

- [ ] **Step 3: Implement**

In `orchestrator/lib/mix/tasks/release.manifest.ex`:

Add `channel: :string` and `artifact_base: :string` to `@switches`:

```elixir
  @switches [
    version: :string,
    channel: :string,
    tag: :string,
    upstream_sha: :string,
    out: :string,
    root: :string,
    clt_fingerprint: :string,
    artifact_base: :string
  ]
```

In `run/1`, after `version = required(opts, :version)`, add:

```elixir
    channel = required(opts, :channel)
    base = opts[:artifact_base] || "djgoku/misemacs"
```

Change the `manifest = %{...}` map to add the two top-level keys:

```elixir
    manifest = %{
      "schema" => 1,
      "channel" => channel,
      "repo" => Orchestrator.Naming.artifact_repo(base, channel),
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

Add `Orchestrator.Naming` to the `alias` line: `alias Orchestrator.{Core.Hash, Manifest, Naming}` and use `Naming.artifact_repo(base, channel)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd orchestrator && mix test test/mix/tasks/release_manifest_test.exs`
Expected: PASS

- [ ] **Step 5: Update the daily.yml manifest-fragment step's args (note-only here; full CI in Task 10)**

The `manifest fragment` step in `daily.yml` calls `mix release.manifest`. It must now also pass `--channel "${{ matrix.channel }}"` and `--artifact-base "${{ env.ARTIFACT_BASE }}"`. This is applied in Task 10; recorded here so the contract is visible.

- [ ] **Step 6: Run full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add orchestrator/lib/mix/tasks/release.manifest.ex orchestrator/test/mix/tasks/release_manifest_test.exs
git commit -m "feat(orchestrator): manifest fragment stamps channel + artifact repo"
```

---

## Task 4: `Core.Latest` — newest-by-sort

Resolution is `github_tag` (sort-based), and finalize runs per-repo (Task 5/10), so within one finalize the tags are all one channel. The latest tag is the **lexical max** (zero-padded ISO dates + `.N` collision suffixes sort newest), not recency-order `List.last`. This drops the fragile "caller must pass recency order" contract.

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
Expected: FAIL — the unordered/`.N` cases return the wrong tag (current `List.last`).

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

## Task 5: `finalize` filters fragments to its `--repo`

`mix orchestrate.finalize --repo <channel-repo>` is invoked once per channel by the CI matrix (Task 10). It must use only the fragments belonging to that repo (the `repo` field from Task 3), so a stray cross-channel fragment can't pollute one channel's manifest or latest tag.

**Files:**
- Modify: `orchestrator/lib/orchestrator/orchestrate.ex` (`finalize_outputs/3`)
- Modify: `orchestrator/lib/mix/tasks/orchestrate.finalize.ex`
- Test: `orchestrator/test/orchestrator/orchestrate_test.exs`

- [ ] **Step 1: Write the failing test**

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

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs`
Expected: FAIL — `finalize_outputs/3`'s 3rd arg is currently `built_tags` (a list), not a repo string; arity/shape mismatch.

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

- [ ] **Step 4: Update the finalize task to the new shape**

In `orchestrator/lib/mix/tasks/orchestrate.finalize.ex`, replace `exec/2` and drop the old `built_tags/1` helper (its logic moved into `finalize_outputs`):

```elixir
  def exec(opts, deps \\ default_deps()) do
    fragments = read_fragments(opts[:fragments] || ".")
    repo = opts[:repo]
    prior =
      case deps.releases.(repo) do
        {:ok, manifest} -> manifest
        :empty -> nil
        {:error, reason} -> Mix.raise("finalize: cannot read prior manifest for #{repo}: #{inspect(reason)}")
      end

    Orchestrate.finalize_outputs(prior, fragments, repo)
  end
```

The `emit/2` function already prints `latest_tag=` and `built_tags=` from the result map; it works unchanged because `finalize_outputs` now returns `:built_tags`. Remove the `Map.put(:built_tags, tags)` that previously wrapped `exec` (it's now inside `finalize_outputs`), and update the `emit` pattern match if needed to `%{manifest: manifest, latest_tag: tag, built_tags: tags}`.

> Note: `deps.releases.(repo)` now returns the three-way result from Task 6. If Task 6 is implemented after this task, temporarily treat the current `nil`-returning adapter by wrapping: `case deps.releases.(repo) do nil -> nil; m -> m end`. Recommended: implement Task 6 immediately after this step so the contract is consistent; the full-suite run in Step 6 will catch a mismatch.

- [ ] **Step 5: Run the targeted tests**

Run: `cd orchestrator && mix test test/orchestrator/orchestrate_test.exs test/mix/tasks/orchestrate_finalize_test.exs`
Expected: PASS. Update `orchestrate_finalize_test.exs` fixtures so fragments include a `"repo"` key and the stub `deps.releases` returns `{:ok, manifest}` / `:empty` (aligns with Task 6).

- [ ] **Step 6: Full suite + commit**

Run: `cd orchestrator && mix test`
Expected: PASS

```bash
git add orchestrator/lib/orchestrator/orchestrate.ex orchestrator/lib/mix/tasks/orchestrate.finalize.ex orchestrator/test/orchestrator/orchestrate_test.exs orchestrator/test/mix/tasks/orchestrate_finalize_test.exs
git commit -m "feat(orchestrator): per-repo finalize (filter fragments by repo, newest tag)"
```

---

## Task 6: `Releases` three-way + sort-newest read

`last_manifest/1` must distinguish a reachable-but-empty repo (genuine first run) from an unreachable/auth-failed/corrupt one (must fail loudly), and read the state from the **sort-newest** tag rather than the cosmetic Latest marker. Split the IO from a pure classifier so the decision is unit-testable.

**Files:**
- Modify: `orchestrator/lib/orchestrator/releases.ex` (callback type)
- Modify: `orchestrator/lib/orchestrator/releases/gh.ex`
- Test: `orchestrator/test/orchestrator/releases_test.exs`

- [ ] **Step 1: Write the failing tests (pure classifier)**

Add to `orchestrator/test/orchestrator/releases_test.exs`:

```elixir
  alias Orchestrator.Releases.Gh

  test "classify: list failed => :error" do
    assert {:error, _} = Gh.classify({:error, :gh_failed}, fn _tag -> :unused end)
  end

  test "classify: reachable, no tags => :empty" do
    assert Gh.classify({:ok, []}, fn _tag -> raise "should not fetch" end) == :empty
  end

  test "classify: picks the lexical-newest tag and returns its manifest" do
    fetched =
      fn
        "emacs-31-2026-06-29" -> %{"versions" => %{"emacs-31" => %{}}}
        _ -> nil
      end

    assert {:ok, %{"versions" => _}} =
             Gh.classify({:ok, ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]}, fetched)
  end

  test "classify: tags exist but none has a manifest => :error (not silent first-run)" do
    assert {:error, _} = Gh.classify({:ok, ["emacs-31-2026-06-29"]}, fn _ -> nil end)
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/releases_test.exs`
Expected: FAIL — `Gh.classify/2` undefined.

- [ ] **Step 3: Implement the pure classifier + rewire IO**

In `orchestrator/lib/orchestrator/releases/gh.ex`, replace `last_manifest/1` and the `latest_tag`/`recent_tags` helpers with a sort-newest listing + the pure classifier:

```elixir
  @impl true
  def last_manifest(repo) do
    classify(list_tags(repo), &fetch(repo, &1))
  end

  @doc """
  Pure decision over `list_tags` result + a `fetch.(tag)` fun:
    * `{:error, _}` list        -> `{:error, reason}`
    * `{:ok, []}`               -> `:empty` (reachable, no releases = first run)
    * `{:ok, tags}`             -> newest-first, first tag whose fetch yields a manifest -> `{:ok, m}`
    * tags present, none yields  -> `{:error, :no_manifest}` (must NOT look like first-run)
  """
  @spec classify({:ok, [String.t()]} | {:error, term()}, (String.t() -> map() | nil)) ::
          {:ok, map()} | :empty | {:error, term()}
  def classify({:error, reason}, _fetch), do: {:error, reason}
  def classify({:ok, []}, _fetch), do: :empty

  def classify({:ok, tags}, fetch) do
    tags
    |> Enum.sort(:desc)
    |> Enum.find_value(fn tag -> fetch.(tag) end)
    |> case do
      nil -> {:error, :no_manifest}
      manifest -> {:ok, manifest}
    end
  end

  # IO: list release tags; {:ok, [tag]} on success (possibly empty), {:error, _} on failure.
  defp list_tags(repo) do
    case gh(["release", "list", "--repo", repo, "--limit", "100", "--json", "tagName", "--jq", ".[].tagName"]) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
```

Keep the existing private `fetch/2`, `parse_manifest/*`, `trim_nil/1`, and `gh/1` functions as-is (delete only the now-unused `latest_tag/1`, `recent_tags/1`, and the `@scan` attribute).

- [ ] **Step 4: Update the behaviour callback type**

In `orchestrator/lib/orchestrator/releases.ex`:

```elixir
  @callback last_manifest(repo :: String.t()) :: {:ok, map()} | :empty | {:error, term()}
```

Update the moduledoc's "returns `nil`" wording to describe the three-way result.

- [ ] **Step 5: Run tests**

Run: `cd orchestrator && mix test test/orchestrator/releases_test.exs`
Expected: PASS (classifier + the existing `parse_manifest` tests).

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/releases.ex orchestrator/lib/orchestrator/releases/gh.ex orchestrator/test/orchestrator/releases_test.exs
git commit -m "feat(orchestrator): last_manifest three-way (:ok/:empty/:error) + sort-newest read"
```

---

## Task 7: `decide` reads N per-channel manifests + preflight

In detect mode, `decide` reads each channel's manifest from its own artifact repo, **fails the run** on `:error`, treats `:empty` as first-run, and merges the `:ok` ones into the single combined manifest `decide_outputs` already consumes.

**Files:**
- Modify: `orchestrator/lib/mix/tasks/orchestrate.decide.ex` (`exec/2`)
- Test: `orchestrator/test/mix/tasks/orchestrate_decide_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `orchestrator/test/mix/tasks/orchestrate_decide_test.exs` a detect-mode test with a stub `releases` dep that returns per-repo three-way results. Match the existing test's `deps` injection shape (it already stubs `:upstream`, `:toolchain`, `:releases`). Example:

```elixir
  test "detect: :error from any channel repo aborts" do
    deps = %{
      upstream: fn _v -> "sha" end,
      toolchain: fn -> "clt" end,
      releases: fn
        "djgoku/misemacs-emacs-master" -> {:error, :unauthorized}
        repo -> flunk("unexpected repo #{repo}")
      end
    }

    assert_raise Mix.Error, ~r/unauthorized/, fn ->
      Mix.Tasks.Orchestrate.Decide.exec(
        %{repo: "djgoku/misemacs", date: "2026-06-29", mode: "detect", root: ".."},
        deps
      )
    end
  end

  test "detect: :empty channel is treated as first-run (builds)" do
    deps = %{
      upstream: fn _v -> "newsha" end,
      toolchain: fn -> "clt" end,
      releases: fn _repo -> :empty end
    }

    out = Mix.Tasks.Orchestrate.Decide.exec(
      %{repo: "djgoku/misemacs", date: "2026-06-29", mode: "detect", root: ".."},
      deps
    )

    assert out.any == true
  end
```

> Adapt the `deps` keys/fixtures to the exact shape the existing decide tests use (check `default_deps/0` and the current passing tests for the stub names). The point: stub `releases` per-repo.

- [ ] **Step 2: Run to verify it fails**

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_decide_test.exs`
Expected: FAIL — `exec` currently calls `deps.releases.(repo)` once for the source repo, not per channel; `:error` isn't raised.

- [ ] **Step 3: Implement the per-channel read in `exec`**

In `orchestrator/lib/mix/tasks/orchestrate.decide.ex`, replace the detect branch that builds `manifest`. The current code is:

```elixir
    {states, manifest} =
      if mode == "detect" do
        clt = deps.toolchain.()
        {current_states(versions, root, clt, deps.upstream), deps.releases.(fetch!(opts, :repo))}
      else
        {%{}, nil}
      end
```

Replace with:

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

Add these private helpers (alongside `artifact_base/1` from Task 2):

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

(`versions` here is the `[%{name, channel, ref}]` list from `Manifest.versions!/1`; confirm it exposes `.channel` — it does, per `Manifest.versions!`.)

- [ ] **Step 4: Run the decide tests**

Run: `cd orchestrator && mix test test/mix/tasks/orchestrate_decide_test.exs`
Expected: PASS. Update any pre-existing detect test whose `releases` stub returned a bare manifest map → wrap as `{:ok, manifest}`.

- [ ] **Step 5: Full suite**

Run: `cd orchestrator && mix test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/mix/tasks/orchestrate.decide.ex orchestrator/test/mix/tasks/orchestrate_decide_test.exs
git commit -m "feat(orchestrator): decide reads per-channel manifests + preflight aborts on :error"
```

---

## Task 8: Registry repoint (keep `github_tag`) + contract test

Point each aqua package at its artifact repo and **add** `version_source: github_tag` (kept per D5). Update the contract test so drift is caught.

**Files:**
- Modify: `aqua/registry.yaml`
- Test: `orchestrator/test/orchestrator/registry_contract_test.exs`

- [ ] **Step 1: Inspect the current contract test**

Run: `cat orchestrator/test/orchestrator/registry_contract_test.exs`
Note how it loads `aqua/registry.yaml` and which fields it asserts (package names, `version_prefix`, asset template). You will add `repo_owner`/`repo_name` and `version_source` assertions in the same style.

- [ ] **Step 2: Write the failing assertions**

Add to `orchestrator/test/orchestrator/registry_contract_test.exs`, following the file's existing YAML-loading helper (call it `packages()` or reuse the existing accessor):

```elixir
  test "each package points at its per-channel artifact repo" do
    by_name = Map.new(packages(), &{&1["name"], &1})

    assert by_name["djgoku/misemacs-emacs-master"]["repo_owner"] == "djgoku"
    assert by_name["djgoku/misemacs-emacs-master"]["repo_name"] == "misemacs-emacs-master"
    assert by_name["djgoku/misemacs-emacs-31"]["repo_owner"] == "djgoku"
    assert by_name["djgoku/misemacs-emacs-31"]["repo_name"] == "misemacs-emacs-31"
  end

  test "both packages keep version_source: github_tag (marker-independent @latest)" do
    for p <- packages() do
      assert p["version_source"] == "github_tag", "#{p["name"]} must set version_source: github_tag"
    end
  end
```

(If the test file has no `packages()` accessor, add one mirroring its existing load: read `../aqua/registry.yaml`, `YamlElixir.read_from_string!/1` or the lib it already uses, return `m["packages"]`.)

- [ ] **Step 3: Run to verify it fails**

Run: `cd orchestrator && mix test test/orchestrator/registry_contract_test.exs`
Expected: FAIL — `repo_name` is still `misemacs`; no `version_source`.

- [ ] **Step 4: Edit `aqua/registry.yaml`**

For the `djgoku/misemacs-emacs-master` package: change `repo_name: misemacs` → `repo_name: misemacs-emacs-master` and add `version_source: github_tag` right after the `name:` line. Do the same for `djgoku/misemacs-emacs-31` (→ `repo_name: misemacs-emacs-31`). `repo_owner` stays `djgoku`. Leave `type`, `version_prefix`, `asset`, `format`, `checksum`, `overrides`, `replacements` unchanged. Result per package (master shown):

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

In `pipeline/publish`, after the existing block that sets `CHANNEL="${CHANNEL:-$VERSION}"` (around line 21) and before `DATE=...`, insert:

```bash
# Derived-name assertion (data validation, NOT an auth gate — see spec D2/§4.5):
# the target repo MUST be this channel's artifact repo. Catches a bad/empty matrix.repo
# before any gh write.
EXPECTED_REPO="${MISEMACS_ARTIFACT_BASE:-djgoku/misemacs}-emacs-$CHANNEL"
if [ "$REPO" != "$EXPECTED_REPO" ]; then
  echo "FATAL: --repo '$REPO' != expected artifact repo '$EXPECTED_REPO' for channel '$CHANNEL'"; exit 1
fi
```

- [ ] **Step 2: Verify the publish guard rejects a mismatch (no network reached)**

Run:
```bash
MISEMACS_ARTIFACT_BASE=djgoku/misemacs bash pipeline/publish --repo djgoku/wrong --version master --channel master
```
Expected: prints `FATAL: --repo 'djgoku/wrong' != expected artifact repo 'djgoku/misemacs-emacs-master' for channel 'master'` and exits non-zero, **before** any `git ls-remote`/`gh` call.

- [ ] **Step 3: Add the assertion to `pipeline/promote`**

`promote` receives `--tag` but not `--channel`; derive the channel from the tag (`emacs-<channel>-<date>[.N]`). In `pipeline/promote`, after the arg-parse `while` loop and the `[ -n "$REPO" ] && [ -n "$TAG" ]` usage check (around line 22), insert:

```bash
# Derive channel from the tag (emacs-<channel>-YYYY-MM-DD[.N]) and assert the repo.
CH="$(printf '%s' "$TAG" | sed -E 's/^emacs-(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$/\1/')"
EXPECTED_REPO="${MISEMACS_ARTIFACT_BASE:-djgoku/misemacs}-emacs-$CH"
if [ "$CH" = "$TAG" ] || [ "$REPO" != "$EXPECTED_REPO" ]; then
  echo "FATAL: promote --repo '$REPO' / --tag '$TAG' — expected repo '$EXPECTED_REPO' (channel '$CH')"; exit 1
fi
```

- [ ] **Step 4: Verify the promote guard**

Run:
```bash
MISEMACS_ARTIFACT_BASE=djgoku/misemacs bash pipeline/promote --repo djgoku/wrong --tag emacs-31-2026-06-29
```
Expected: prints a `FATAL: promote ... expected repo 'djgoku/misemacs-emacs-31' (channel '31')` and exits non-zero.

Also verify the happy-path channel parse (does not exit on the assertion):
```bash
# master with .N suffix
printf 'emacs-master-2026-06-29.2' | sed -E 's/^emacs-(.+)-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$/\1/'
```
Expected output: `master`

- [ ] **Step 5: Commit**

```bash
git add pipeline/publish pipeline/promote
git commit -m "feat(pipeline): assert --repo matches the channel's artifact repo (data validation)"
```

---

## Task 10: `daily.yml` — App token JIT, `matrix.repo`, per-channel finalize matrix

CI wiring. Not unit-testable; verify by reading the diff and a dry-run PR. Apply each edit, then validate with `actionlint` if available and a `workflow_dispatch` dry run.

**Files:**
- Modify: `.github/workflows/daily.yml`

Prereqs (one-time, manual — outside this repo): create `djgoku/misemacs-emacs-master` and `djgoku/misemacs-emacs-31`; create a GitHub App with **contents: write**, install it on both repos; add repo secrets `MISEMACS_APP_ID` and `MISEMACS_APP_PRIVATE_KEY`. (Recorded in Task 11's checklist.)

- [ ] **Step 1: Add a workflow-level env for the artifact base**

Near the top-level `env:`/`permissions:` of `daily.yml`, add (so every job/step can derive repos consistently with the orchestrator default):

```yaml
env:
  ARTIFACT_BASE: djgoku/misemacs
```

- [ ] **Step 2: Mint the App token just before publish, scoped to the channel's repo**

In the `build` job, immediately **before** the `publish (real) ...` step, add a token step (only in the real, non-dry-run path it's still fine to mint; the publish step guards dry-run internally):

```yaml
      - name: mint publish token (App, just-in-time)
        if: needs.decide.outputs.dry_run != 'true'
        id: pubtoken
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.MISEMACS_APP_ID }}
          private-key: ${{ secrets.MISEMACS_APP_PRIVATE_KEY }}
          owner: djgoku
          repositories: ${{ format('misemacs-emacs-{0}', matrix.channel) }}
```

Then in the `publish (real) or package+artifact (dry-run)` step, set its env to use the minted token and pass `--repo "${{ matrix.repo }}"`:

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

- [ ] **Step 3: Pass channel + artifact base to the manifest fragment step**

Update the `manifest fragment (real only)` step's `mix release.manifest` call to add `--channel` and `--artifact-base` (Task 3 made these required/used):

```yaml
          (cd orchestrator && mise exec -- mix release.manifest \
            --version "${{ matrix.name }}" --channel "${{ matrix.channel }}" \
            --artifact-base "${{ env.ARTIFACT_BASE }}" \
            --tag "$TAG" --upstream-sha "$SHA" \
            --root .. --out "../dist/${{ matrix.name }}/build-manifest.json")
```

- [ ] **Step 4: Convert `finalize` to a per-channel matrix**

Replace the single `finalize` job with a matrix over the channels built this run. The `decide` job must expose the list of built `{channel, repo}` pairs. Add to `decide`'s outputs a `channels` JSON (derive in the decide step from the matrix it already emits):

In the `decide` step script, after the existing `grep -E '^(matrix|any|dry_run)=' /tmp/decide.out >> "$GITHUB_OUTPUT"` line, add (parsing the same `matrix=` line the step already emits):
```bash
          # Distinct {channel,repo} built this run, for the finalize matrix.
          MATRIX="$(sed -n 's/^matrix=//p' /tmp/decide.out)"
          CHANNELS="$(printf '%s' "$MATRIX" | jq -c '[.include[] | {channel, repo}] | unique')"
          echo "channels=$CHANNELS" >> "$GITHUB_OUTPUT"
```
and expose `channels: ${{ steps.decide.outputs.channels }}` under the `decide` job's `outputs:` block (alongside the existing `matrix`/`any`/`dry_run`).

Then make `finalize` a matrix job:

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
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.MISEMACS_APP_ID }}
          private-key: ${{ secrets.MISEMACS_APP_PRIVATE_KEY }}
          owner: djgoku
          repositories: ${{ format('misemacs-emacs-{0}', matrix.channel) }}
      - name: finalize + promote this channel
        env:
          GH_TOKEN: ${{ steps.fintoken.outputs.token }}
          MISEMACS_ARTIFACT_BASE: ${{ env.ARTIFACT_BASE }}
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

> `mix orchestrate.finalize` now filters fragments to `--repo` (Task 5), so downloading all `manifest-*` and pointing each cell at its own `--repo` is correct — each cell ignores other channels' fragments.

- [ ] **Step 5: Lint + dry-run validation**

Run (if `actionlint` is installed): `actionlint .github/workflows/daily.yml`
Expected: no errors. Then open a PR (or push a branch) to trigger the `pull_request` dry-run path and confirm: `decide` emits `channels`, `build` runs in dry-run (no token minted, packages a tarball), and `finalize` is skipped (dry-run guard). Inspect the Actions run.

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

In the install/spell-checking/distribution section, document: (a) each channel is its own aqua package living in its own repo (`aqua:djgoku/misemacs-emacs-master`, `…-emacs-31`); (b) `@latest` rolls each channel independently and is marker-independent (`version_source: github_tag`); (c) a freshly-added channel has no installable version until its first daily build publishes; (d) adding a version = the spec §4.10 flow (`versions.toml` + `versions/<name>/` + registry entry + one-time `gh repo create` + App install). Keep the existing prose style.

- [ ] **Step 2: Lab bootstrap (throwaway, non-prod)**

Using base `djgoku/misemacs-lab`:
```bash
gh repo create djgoku/misemacs-lab-emacs-master --public
gh repo create djgoku/misemacs-lab-emacs-31 --public
```
Install the GitHub App on both (or use a lab PAT exported as `GH_TOKEN` for the manual publish below).

- [ ] **Step 3: Publish each channel to its lab repo**

From a build (or reuse an existing `dist/<version>/` artifact), with `MISEMACS_ARTIFACT_BASE=djgoku/misemacs-lab`:
```bash
export MISEMACS_ARTIFACT_BASE=djgoku/misemacs-lab
mise run publish -- --repo djgoku/misemacs-lab-emacs-master --version master --channel master
mise run publish -- --repo djgoku/misemacs-lab-emacs-31 --version emacs-31 --channel 31
```
Expected: each release lands in its own lab repo; the derived-name assertion passes.

- [ ] **Step 4: Prove per-channel resolution + crowding immunity**

Point mise at the lab registry (a registry.yaml variant whose `repo_name`s are the lab repos) and, with a fresh cache:
```bash
MISE_AQUA_REGISTRIES=<raw-lab-registry-url> MISE_CACHE_DIR=$(mktemp -d) MISE_DATA_DIR=$(mktemp -d) \
  MISE_MINIMUM_RELEASE_AGE=0 mise ls-remote 'aqua:djgoku/misemacs-lab-emacs-master'
# repeat for ...-emacs-31
```
Expected: each resolves to its **own** newest release, independent of the other's volume.

- [ ] **Step 5: Prove marker-independence (failed-finalize simulation)**

On the lab master repo, flip Latest to an older release (`gh release edit <old-tag> --repo djgoku/misemacs-lab-emacs-master --latest`), then re-resolve `@latest` with a fresh cache:
```bash
MISE_AQUA_REGISTRIES=<raw-lab-registry-url> MISE_CACHE_DIR=$(mktemp -d) MISE_DATA_DIR=$(mktemp -d) \
  MISE_MINIMUM_RELEASE_AGE=0 mise latest 'aqua:djgoku/misemacs-lab-emacs-master@latest'
```
Expected: resolves to the **newest tag**, not the (stale) marker — confirming `github_tag` keeps `@latest` correct even when promote/finalize fails to flip Latest.

- [ ] **Step 6: Record the validated facts in the knowledge base**

Append the confirmed behaviors (per-channel repos remove crowding; `github_tag` `@latest` ignores a stale marker on a real per-channel repo) to `~/.claude/knowledge-base/mise.md` with the lab commands as proof, and add/refresh the index pointer.

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
- [ ] `aqua/registry.yaml` both packages point at artifact repos and retain `version_source: github_tag`; contract test asserts both (Task 8).
- [ ] `Manifest.jobs/3` emits `repo`; `daily.yml` publish + per-channel finalize use `matrix.repo`; App token minted just before publish and before promote (Tasks 2, 10).
- [ ] `publish`/`promote` assert `--repo == <base>-emacs-<channel>` with negative checks (Task 9).
- [ ] Fragments carry `channel` + `repo`; `finalize` filters by repo; `Core.Latest` selects newest by sort, unit-tested for single/multi/`.N` (Tasks 3, 4, 5).
- [ ] `last_manifest/1` reads sort-newest + returns `:ok`/`:empty`/`:error`; `decide` preflight fails loudly on `:error`, treats `:empty` as first-run (Tasks 6, 7).
- [ ] `cd orchestrator && mix test` green across the updated decide/finalize/manifest/registry-contract tests.
- [ ] Lab check: per-channel `@latest` resolves independently; stale-marker simulation still resolves newest tag (Task 11).
- [ ] README updated (Task 11).
```
