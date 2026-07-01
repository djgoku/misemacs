# Artifact-Repo README Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `mix release.artifact_readme --version <name>` task that prints a complete, channel-specific, date-free `README.org` for a per-channel artifact repo — used as that repo's bootstrap commit.

**Architecture:** A new mix task (sibling to `Mix.Tasks.Release.Manifest`) reads `channel` + upstream `ref` for a version from `versions.toml`, derives the repo and source from `Naming.artifact_repo/2` + the artifact base, and renders an Org-mode README to stdout. No network, no file writes (caller redirects). A `mise run artifact-readme` wrapper and doc updates round it out.

**Tech Stack:** Elixir/Mix, ExUnit (`ExUnit.CaptureIO`), mise tasks, Org-mode, GitHub contents API (for the bootstrap PUT, documented only).

**Design spec:** `docs/superpowers/specs/2026-06-30-artifact-repo-readme-design.md`.

**Conventions:** Run Elixir from `orchestrator/`. Full suite: `cd orchestrator && mix test`. Commits are GPG-signed.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `orchestrator/lib/mix/tasks/release.artifact_readme.ex` | the generator task (reads versions.toml, renders Org) | 1 |
| `orchestrator/test/mix/tasks/release_artifact_readme_test.exs` | string-contract test (both channels, install methods, no date) | 1 |
| `mise.toml` | `[tasks.artifact-readme]` wrapper | 2 |
| `README.org` | add-a-version step → use the generator | 3 |
| `docs/superpowers/specs/2026-06-29-per-channel-artifact-repos-design.md` | §4.10 bootstrap → use the generator | 3 |

---

## Task 1: `mix release.artifact_readme` generator + contract test

The render is keyed on `--version`; it derives `channel` + `ref` from `versions.toml` (reusing the exact helpers from `release.manifest.ex`), the artifact `base` (env-or-default, blank-safe), and the repo via `Naming.artifact_repo/2`. The source repo and registry URL derive from `base`. The README contains **no literal date** (it documents the `emacs-<channel>-YYYY-MM-DD` *shape* only).

**Files:**
- Create: `orchestrator/lib/mix/tasks/release.artifact_readme.ex`
- Test: `orchestrator/test/mix/tasks/release_artifact_readme_test.exs`

- [ ] **Step 1: Write the failing contract test**

Create `orchestrator/test/mix/tasks/release_artifact_readme_test.exs`:

```elixir
defmodule Mix.Tasks.Release.ArtifactReadmeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  @registry "MISE_AQUA_REGISTRIES=https://raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml"

  defp gen(version), do: capture_io(fn -> Mix.Tasks.Release.ArtifactReadme.run(["--version", version, "--root", ".."]) end)

  test "master README: repo, channel, ref, and all three install methods" do
    out = gen("master")
    assert out =~ "djgoku/misemacs-emacs-master"
    assert out =~ "=master= channel"
    assert out =~ "=master= ref"
    assert out =~ "mise use aqua:djgoku/misemacs-emacs-master@latest"
    assert out =~ @registry
    assert out =~ "mise use github:djgoku/misemacs-emacs-master@latest"
  end

  test "emacs-31 README: channel \"31\", ref \"emacs-31\", repo, and all three install methods" do
    out = gen("emacs-31")
    assert out =~ "djgoku/misemacs-emacs-31"
    assert out =~ "=31= channel"
    assert out =~ "=emacs-31= ref"
    assert out =~ "emacs-31-YYYY-MM-DD"
    assert out =~ "mise use aqua:djgoku/misemacs-emacs-31@latest"
    assert out =~ @registry
    assert out =~ "mise use github:djgoku/misemacs-emacs-31@latest"
  end

  test "README documents the 3 release assets + verification + source pointer" do
    out = gen("master")
    assert out =~ "build-manifest.json"
    assert out =~ "SHASUMS256.txt"
    assert out =~ "macos-arm64.tar.gz"
    assert out =~ "shasum -c"
    assert out =~ "do not open issues or pull requests here"
  end

  test "README is version-agnostic — contains NO literal date" do
    refute gen("master") =~ ~r/\d{4}-\d{2}-\d{2}/
  end

  test "unknown version raises loudly" do
    assert_raise Mix.Error, ~r/no such version/, fn ->
      capture_io(fn -> Mix.Tasks.Release.ArtifactReadme.run(["--version", "nope", "--root", ".."]) end)
    end
  end
end
```

> The `=master= channel` / `=master= ref` (and `=31= channel` / `=emacs-31= ref`) assertions
> are deliberately distinct: they verify the render uses the *channel* in the "channel" line and
> the *ref* in the "ref" line — which differ for `emacs-31` (channel `31`, ref `emacs-31`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd orchestrator && mix test test/mix/tasks/release_artifact_readme_test.exs`
Expected: FAIL — `Mix.Tasks.Release.ArtifactReadme.run/1 is undefined` (module doesn't exist).

- [ ] **Step 3: Implement the generator**

Create `orchestrator/lib/mix/tasks/release.artifact_readme.ex`:

```elixir
defmodule Mix.Tasks.Release.ArtifactReadme do
  @shortdoc "Print the channel-specific README.org for an artifact repo"
  @moduledoc """
  Renders the static, date-free `README.org` for a per-channel artifact repo
  (`<base>-emacs-<channel>`) to stdout. Keyed on `--version`; derives `channel` + upstream
  `ref` from `versions.toml`. Used as the artifact repo's bootstrap commit. Network-free.

      mix release.artifact_readme --version master [--artifact-base djgoku/misemacs] [--root ..]
  """
  use Mix.Task
  alias Orchestrator.{Manifest, Naming}

  @switches [version: :string, artifact_base: :string, root: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    root = opts[:root] || ".."
    version = opts[:version] || Mix.raise("missing required --version")

    # Reuse the public version list (%{name, channel, ref}) instead of re-parsing versions.toml.
    v =
      Manifest.versions!(root)
      |> Enum.find(&(&1.name == version)) ||
        Mix.raise("no such version #{inspect(version)} in versions.toml")

    base = opts[:artifact_base] || env_base() || "djgoku/misemacs"
    repo = Naming.artifact_repo(base, v.channel)

    IO.puts(render(%{channel: v.channel, ref: v.ref, base: base, repo: repo}))
  end

  defp render(%{channel: channel, ref: ref, base: base, repo: repo}) do
    """
    #+TITLE: misemacs — #{channel} channel (release artifacts)

    Auto-published release bucket for the =#{channel}= channel of
    [[https://github.com/#{base}][#{base}]] — a hermetically-built, relocatable =Emacs.app=
    for macOS (arm64), built from the =#{ref}= ref of
    [[https://github.com/emacsmirror/emacs][emacsmirror/emacs]].

    *Nothing here is hand-edited.* Releases are produced by the daily pipeline in
    [[https://github.com/#{base}][#{base}]] and pushed here automatically.

    * Install (mise)

    Methods in order of preference.

    ** 1. aqua registry (zero-config) — coming soon

    Once this package is in the upstream aqua-registry, no setup is needed:

    #+begin_src sh
    mise use aqua:#{repo}@latest
    #+end_src

    (Not yet submitted upstream — use method 2 or 3 until then.)

    ** 2. Point mise at the misemacs registry (interim)

    #+begin_src sh
    MISE_AQUA_REGISTRIES=https://raw.githubusercontent.com/#{base}/main/aqua/registry.yaml \\
      mise use aqua:#{repo}@latest
    #+end_src

    Versions resolve as the bare date (=YYYY-MM-DD=); =@latest= rolls this channel forward.

    ** 3. GitHub backend (no registry config)

    #+begin_src sh
    mise use github:#{repo}@latest
    #+end_src

    Caveat: the =github:= backend uses the *full tag* as the version
    (=emacs-#{channel}-YYYY-MM-DD=), not the bare date.

    * What's in each release

    | asset | what it is |
    |-------+------------|
    | =misemacs-<tag>-macos-arm64.tar.gz= | the relocatable =Emacs.app= (with bundled enchant for spell-checking) |
    | =SHASUMS256.txt= | sha256 of the tarball, for manual verification |
    | =build-manifest.json= | records the upstream emacs commit + the build-input fingerprint for that release |

    * Verification

    mise verifies GitHub's per-asset digest automatically on both the aqua and =github:=
    install paths. To check by hand: download the tarball + =SHASUMS256.txt= and run
    =shasum -c SHASUMS256.txt=.

    * Versioning

    Tags are CalVer: =emacs-#{channel}-YYYY-MM-DD= (a =.N= suffix is added on same-day
    rebuilds). =@latest= rolls *this channel* independently and is marker-independent — the
    registry uses =version_source: github_tag=, so the newest tag wins, not GitHub's "Latest"
    badge.

    * Source & issues

    This is a generated artifact bucket — *do not open issues or pull requests here.*
    Source code, the build system, and documentation live in
    [[https://github.com/#{base}][#{base}]].
    """
  end

  # Treat blank MISEMACS_ARTIFACT_BASE like unset (mirrors release.manifest + bash ${VAR:-default}).
  defp env_base do
    case System.get_env("MISEMACS_ARTIFACT_BASE") do
      nil -> nil
      "" -> nil
      v -> v
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd orchestrator && mix test test/mix/tasks/release_artifact_readme_test.exs`
Expected: PASS (5 tests). If the `refute date` test fails, search the rendered string for a stray literal date and replace it with the `YYYY-MM-DD` placeholder shape.

- [ ] **Step 5: Eyeball the rendered output**

Run: `cd orchestrator && mix release.artifact_readme --version master --root ..`
Expected: a clean Org README naming `djgoku/misemacs-emacs-master`, three install blocks, the asset table, and the source pointer. Skim for broken `[[link][text]]` or `#+begin_src` pairing.

- [ ] **Step 6: Full suite + warnings**

Run: `cd orchestrator && mix test && mix compile --force --warnings-as-errors 2>&1 | tail -1`
Expected: all green, no warnings.

- [ ] **Step 7: Commit**

```bash
git add orchestrator/lib/mix/tasks/release.artifact_readme.ex orchestrator/test/mix/tasks/release_artifact_readme_test.exs
git commit -m "feat(orchestrator): release.artifact_readme generates per-channel artifact-repo README.org"
```

---

## Task 2: `mise run artifact-readme` wrapper

A thin mise task wrapping the generator, matching the existing `decide`/`finalize` wrappers (which use `dir = "orchestrator"` + `run = "mix orchestrate.<x>"` and rely on mise appending args).

**Files:**
- Modify: `mise.toml`

- [ ] **Step 1: Add the task**

In `mise.toml`, after the `[tasks.finalize]` block, add:

```toml
[tasks.artifact-readme]
description = "Print the channel-specific README.org for an artifact repo; args: --version <name> [--artifact-base <base>]"
dir = "orchestrator"
run = "mix release.artifact_readme"
```

- [ ] **Step 2: Smoke-test the wrapper (arg passthrough)**

Run: `mise run artifact-readme -- --version emacs-31`
Expected: the emacs-31 README prints (naming `djgoku/misemacs-emacs-31`, ref `emacs-31`). This confirms mise appends `--version emacs-31` to the `mix release.artifact_readme` command (per mise's append-args behavior). No `--root` needed: the task's `dir = "orchestrator"` makes the generator's default `--root ..` resolve to the repo root.

- [ ] **Step 3: Commit**

```bash
git add mise.toml
git commit -m "feat(mise): artifact-readme task wraps release.artifact_readme"
```

---

## Task 3: Wire the generator into the bootstrap docs + fix stale wording

The two anchors differ per file: `README.org` already says `--add-readme`; the per-channel spec §4.10 still says plain `--public`. Also fix two pre-existing issues: the main README uses the **deprecated** `MISE_AQUA_REGISTRY_URL` (renamed to `MISE_AQUA_REGISTRIES`), and both docs call a fresh artifact repo "empty" (it now carries the generated README — only *releases* are absent).

**Files:**
- Modify: `README.org`
- Modify: `docs/superpowers/specs/2026-06-29-per-channel-artifact-repos-design.md`

- [ ] **Step 1: README — replace add-a-version step 4 (`--add-readme`) with the generator bootstrap**

EXACT old block in `README.org` (around line 144):
```
4. Create the artifact repo (one-time). It MUST have an initial commit — GitHub returns =HTTP 422 "Repository is empty"= when you try to create the first release/tag on a repo with no default branch, so pass =--add-readme=:
   #+begin_src sh
   gh repo create djgoku/misemacs-emacs-<channel> --public --add-readme
   #+end_src
```
Replace with:
```
4. Create the artifact repo and seed it with its generated README (one-time — the README is the required initial commit; without it GitHub returns =HTTP 422 "Repository is empty"= on the first release):
   #+begin_src sh
   gh repo create djgoku/misemacs-emacs-<channel> --public
   mise run artifact-readme -- --version <name> > /tmp/r.org
   gh api repos/djgoku/misemacs-emacs-<channel>/contents/README.org -X PUT \
     -f message="init: artifact repo" -f content="$(base64 -i /tmp/r.org)"
   #+end_src
```

- [ ] **Step 2: README — rename the deprecated env var (2 spots)**

`MISE_AQUA_REGISTRY_URL` is deprecated → `MISE_AQUA_REGISTRIES` (same value/URL). Replace both occurrences in `README.org`:
- line 24 export: `export MISE_AQUA_REGISTRY_URL=https://raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml` → `export MISE_AQUA_REGISTRIES=https://raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml`
- line 50 prose: `=MISE_AQUA_REGISTRY_URL= continues to point at it.` → `=MISE_AQUA_REGISTRIES= continues to point at it.`

Then `grep -n MISE_AQUA_REGISTRY_URL README.org` — expect **no matches**.

- [ ] **Step 3: README — fix the "starts empty" wording (line 56)**

Replace in `README.org`:
```
*Fresh-channel caveat.* A newly-added channel has no installable version until its first daily build publishes — its artifact repo starts empty.
```
with:
```
*Fresh-channel caveat.* A newly-added channel has no installable version until its first daily build publishes — its artifact repo has no releases yet.
```

- [ ] **Step 4: Spec §4.10 step 4 — replace the `--public` bootstrap**

In `docs/superpowers/specs/2026-06-29-per-channel-artifact-repos-design.md`, EXACT old text (§4.10 step 4):
```
4. **Bootstrap the artifact repo (D4: decided — manual):** run `gh repo create
   djgoku/misemacs-emacs-30 --public` once (~10 s), then install the GitHub App on it. CI does
   **not** create repos — keeping the App's permission to contents-only (least privilege). If the
   repo/App/registry aren't in place, the §4.8 preflight fails the next run loudly (and it
   re-runs cleanly once they exist).
```
Replace with:
```
4. **Bootstrap the artifact repo (D4: decided — manual):** create it and seed its generated
   README (the README is the required initial commit — an empty repo 422s on the first release):
   `gh repo create djgoku/misemacs-emacs-30 --public`, then `mise run artifact-readme -- --version
   emacs-30 > /tmp/r.org` and `gh api repos/djgoku/misemacs-emacs-30/contents/README.org -X PUT -f
   message="init: artifact repo" -f content="$(base64 -i /tmp/r.org)"`, then install the GitHub App
   on it. The README is generated by `mix release.artifact_readme` (single source of truth). CI does
   **not** create repos — keeping the App's permission to contents-only (least privilege). If the
   repo/App/registry aren't in place, the §4.8 preflight fails the next run loudly (and it re-runs
   cleanly once they exist).
```

- [ ] **Step 5: Spec §4.8 — "is empty" → "has no releases"**

In the same spec, the §4.8 "A channel that never built" bullet currently reads (wrapped across two lines): `…its artifact repo is` / `empty, so …`. Read the bullet and change `its artifact repo is empty, so` to `its artifact repo has no releases, so` (preserve the existing line wrap/indentation — it's a two-word edit: `is`→`has no`, `empty`→`releases`).

- [ ] **Step 6: Full suite (docs don't affect tests, but confirm nothing else broke) + commit**

Run: `cd orchestrator && mix test` — green.
```bash
git add README.org docs/superpowers/specs/2026-06-29-per-channel-artifact-repos-design.md
git commit -m "docs: bootstrap artifact repos via generated README; MISE_AQUA_REGISTRIES; 'no releases yet'"
```

---

## Task 4 (manual): live render check on a lab repo

Not code — a DoD verification the implementer runs once.

- [ ] **Step 1: Generate + PUT to a lab artifact repo**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs
MISEMACS_ARTIFACT_BASE=djgoku/misemacs-phase5-lab \
  mise run artifact-readme -- --version master > /tmp/r.org
gh api repos/djgoku/misemacs-phase5-lab-emacs-master/contents/README.org -X PUT \
  -f message="docs: generated artifact-repo README" \
  -f content="$(base64 -i /tmp/r.org)" --jq '.commit.sha'
```
(The `MISEMACS_ARTIFACT_BASE` env = the lab base so the README's links + repo names point at the
lab; the task's `dir = "orchestrator"` makes the default `--root ..` resolve to the repo root.
If a `README.org` already exists in the lab repo, add `-f sha="$(gh api
repos/djgoku/misemacs-phase5-lab-emacs-master/contents/README.org --jq .sha)"` to update it.)

- [ ] **Step 2: Confirm it renders**

Open `https://github.com/djgoku/misemacs-phase5-lab-emacs-master` and confirm the README renders as Org (headings, source blocks, the asset table, working links). No commit needed — this is verification only.

---

## Definition of Done (from spec §4)

- [ ] `mix release.artifact_readme --version <name>` prints a channel-filled, date-free `README.org`; `mise run artifact-readme` wrapper passes args through (Tasks 1, 2).
- [ ] Contract test green: both channels, all three install methods, the 3 assets, verification, source pointer, and `refute` a literal date (Task 1).
- [ ] `cd orchestrator && mix test` + `mix compile --warnings-as-errors` clean.
- [ ] Main README + per-channel spec §4.10 bootstrap use the generator (Task 3).
- [ ] Manual: generated README PUT to a lab artifact repo renders correctly on GitHub (Task 4).
