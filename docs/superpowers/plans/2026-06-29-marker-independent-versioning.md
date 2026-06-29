# Marker-Independent Per-Channel Versioning — Implementation Plan

> **SUPERSEDED (2026-06-29) — DO NOT EXECUTE.** Replaced by the per-channel artifact-repos design
> ([`../specs/2026-06-29-per-channel-artifact-repos-design.md`](../specs/2026-06-29-per-channel-artifact-repos-design.md))
> and its forthcoming plan. The successor keeps `version_source: github_tag` but drops the
> master-only `Core.Latest` rewrite and the `promote` non-master guard described below. Nothing
> here was implemented (docs-only).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make mise resolve each channel's `@latest` from the GitHub tag list (ignoring the repo-wide Latest marker), and constrain the Latest marker so only the `master` channel ever holds it.

**Architecture:** Add `version_source: github_tag` to both aqua packages so mise enumerates versions from tags, not the releases-latest marker (proven: download+checksum still work). Make `Orchestrator.Core.Latest` select only the newest `emacs-master-` tag (`:unchanged` otherwise), and add a defensive refusal in `pipeline/promote` so `--latest` can never land on a non-master tag.

**Tech Stack:** Elixir (ExUnit, `mix`), bash (`pipeline/promote`), aqua registry YAML, mise tasks.

**Spec:** `docs/superpowers/specs/2026-06-29-marker-independent-versioning-design.md`

**Branch:** `enchant-task6` (per user decision — same branch as the enchant work).

---

## File Structure

- `orchestrator/lib/orchestrator/core/latest.ex` — **modify**: master-only selection (pure, no IO).
- `orchestrator/test/orchestrator/core/latest_test.exs` — **modify**: master-only cases.
- `aqua/registry.yaml` — **modify**: add `version_source: github_tag` to both packages.
- `orchestrator/test/orchestrator/registry_contract_test.exs` — **modify**: assert the field.
- `pipeline/promote` — **modify**: refuse `--latest` on a non-`emacs-master-` tag.
- `orchestrator/test/mix/tasks/orchestrate_finalize_test.exs` — **modify**: emacs-31-only run ⇒ no flip; fix a stale comment.
- `orchestrator/test/orchestrator/orchestrate_test.exs` — **modify**: add an emacs-31-only `finalize_outputs` case.
- `README.org` — **modify**: per-channel `@latest`, no-`--bump`, cosmetic master badge, `--cleanup-tag` caveat.

`Orchestrator.Orchestrate.finalize_outputs/3` and `Mix.Tasks.Orchestrate.Finalize` need **no code change** — they call `Latest.latest_target/1`, whose behavior (not signature) changes.

---

## Task 1: `Core.Latest` — master-only Latest selection

**Files:**
- Modify: `orchestrator/lib/orchestrator/core/latest.ex`
- Test: `orchestrator/test/orchestrator/core/latest_test.exs`

- [ ] **Step 1: Replace the test file with master-only cases**

```elixir
defmodule Orchestrator.Core.LatestTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Latest

  test "nothing built => :unchanged" do
    assert Latest.latest_target([]) == :unchanged
  end

  test "only non-master channels built => :unchanged (marker stays on prior master)" do
    assert Latest.latest_target(["emacs-31-2026-06-29", "emacs-31-2026-06-29.1"]) == :unchanged
  end

  test "a master build becomes latest" do
    assert Latest.latest_target(["emacs-master-2026-06-05"]) == {:set, "emacs-master-2026-06-05"}
  end

  test "master is chosen even when a non-master tag sorts later in the list" do
    assert Latest.latest_target(["emacs-master-2026-06-29", "emacs-31-2026-06-29.1"]) ==
             {:set, "emacs-master-2026-06-29"}
  end

  test "newest master tag wins, incl. the .N collision suffix" do
    tags = ["emacs-master-2026-06-28", "emacs-master-2026-06-29", "emacs-master-2026-06-29.1"]
    assert Latest.latest_target(tags) == {:set, "emacs-master-2026-06-29.1"}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/core/latest_test.exs'`
Expected: FAIL — the current `List.last/1` impl returns `{:set, "emacs-31-2026-06-29.1"}` for the non-master case (expected `:unchanged`).

- [ ] **Step 3: Implement master-only selection**

Replace the body of `orchestrator/lib/orchestrator/core/latest.ex` with:

```elixir
defmodule Orchestrator.Core.Latest do
  @moduledoc """
  Pure 'latest' selection. No IO.

  Policy: only the **master** channel may hold GitHub's repo-wide "Latest" marker.
  `latest_target/1` picks the newest `emacs-master-` tag built this run; `:unchanged`
  when master did not build (the marker stays on the previous master release, which
  still exists). Non-master channels are never marked Latest — their consumers resolve
  via mise's per-`version_prefix` tag list (`version_source: github_tag`), which does not
  consult the marker. Newest = lexical max: zero-padded ISO dates sort chronologically
  and the `.N` collision suffix sorts after the bare date.
  """
  alias Orchestrator.Naming

  @master_prefix Naming.tag_base("master", "")

  @spec latest_target([String.t()]) :: {:set, String.t()} | :unchanged
  def latest_target(built_tags) when is_list(built_tags) do
    built_tags
    |> Enum.filter(&String.starts_with?(&1, @master_prefix))
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> :unchanged
      tag -> {:set, tag}
    end
  end
end
```

> `Naming.tag_base("master", "")` evaluates to `"emacs-master-"` — keeps the channel
> string in one place. It is a module attribute (compile-time constant), so `Naming` is a
> compile-time dependency only.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/core/latest_test.exs'`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add orchestrator/lib/orchestrator/core/latest.ex orchestrator/test/orchestrator/core/latest_test.exs
git commit -m "feat(versioning): Core.Latest selects only the newest master tag"
```

---

## Task 2: Update finalize/orchestrate tests for master-only behavior

**Files:**
- Modify: `orchestrator/test/orchestrator/orchestrate_test.exs:49-58`
- Modify: `orchestrator/test/mix/tasks/orchestrate_finalize_test.exs` (the multi-version test ~line 60-87)

- [ ] **Step 1: Add an emacs-31-only case to `orchestrate_test.exs`**

After the existing `"finalize_outputs with no built tags => latest_tag nil"` test, add:

```elixir
  test "finalize_outputs with only a non-master build => latest_tag nil (no flip)" do
    frag = %{"versions" => %{"emacs-31" => %{"released_tag" => "emacs-31-2026-06-29"}}}
    out = Orchestrate.finalize_outputs(nil, [frag], ["emacs-31-2026-06-29"])
    assert out.latest_tag == nil
    assert out.manifest["versions"]["emacs-31"]["released_tag"] == "emacs-31-2026-06-29"
  end
```

> `latest_target` returns `:unchanged` for a non-master-only run; `finalize_outputs`
> maps `:unchanged -> nil` (existing code), so `latest_tag` is `nil` ⇒ the finalize job's
> `if [ -z "$LATEST_TAG" ]` guard skips the flip. The manifest still merges the emacs-31
> fragment (built_tags still attaches it).

- [ ] **Step 2: Fix the stale comment + add an emacs-31-only assertion in `orchestrate_finalize_test.exs`**

In the multi-version test (builds emacs-31 + master), change the comment on the
`latest_tag` assertion from the `List.last` rationale to the master-only rule:

```elixir
    # latest_tag is the master tag (master-only Latest policy); built_tags lists both.
    assert printed =~ "built_tags=emacs-31-2026-06-15 emacs-master-2026-06-15"
    assert printed =~ "latest_tag=emacs-master-2026-06-15"
```

Then add a new test (after that one) for an emacs-31-only run:

```elixir
  test "non-master-only run => latest_tag empty (no flip)", %{dir: dir, out: out} do
    File.write!(
      Path.join(dir, "manifest-emacs-31.json"),
      ~s({"versions":{"emacs-31":{"released_tag":"emacs-31-2026-06-15"}}})
    )

    printed = run_finalize(dir, out)

    assert printed =~ ~r/^latest_tag=\s*$/m
    assert printed =~ "built_tags=emacs-31-2026-06-15"
  end
```

> Reuse whatever helper the existing tests use to invoke finalize and capture stdout
> (named `run_finalize`/similar in this file — match the existing call style; do not
> introduce a new helper). If the existing tests inline the call, inline it the same way.

- [ ] **Step 3: Run the finalize/orchestrate tests**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/orchestrate_test.exs test/mix/tasks/orchestrate_finalize_test.exs'`
Expected: PASS (including the two new cases).

- [ ] **Step 4: Commit**

```bash
git add orchestrator/test/orchestrator/orchestrate_test.exs orchestrator/test/mix/tasks/orchestrate_finalize_test.exs
git commit -m "test(versioning): finalize flips Latest only for master runs"
```

---

## Task 3: Registry — `version_source: github_tag` on both packages

**Files:**
- Modify: `aqua/registry.yaml`
- Test: `orchestrator/test/orchestrator/registry_contract_test.exs`

- [ ] **Step 1: Add the contract assertion (failing test first)**

In `registry_contract_test.exs`, extend the existing per-channel test
`"one version_prefix package per channel (name + prefix bound)"` (or add a sibling test)
with:

```elixir
  test "each channel package resolves versions from tags (version_source: github_tag)",
       %{registry: reg} do
    # One `version_source: github_tag` per package — count must equal the channel count so
    # the marker-independent resolution holds for every channel.
    assert length(Regex.scan(~r/^\s+version_source:\s+github_tag\b/m, reg)) ==
             length(Regex.scan(~r/^\s+version_prefix:/m, reg))
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/registry_contract_test.exs'`
Expected: FAIL — `version_source` not present yet (count 0 ≠ 2).

- [ ] **Step 3: Add `version_source: github_tag` to both packages**

In `aqua/registry.yaml`, for **each** package (the `-emacs-master` and `-emacs-31`
entries), add the line directly under the `version_prefix:` line (same indentation):

```yaml
    version_source: github_tag
```

So each package reads (master shown; mirror for `emacs-31`):

```yaml
  - type: github_release
    name: djgoku/misemacs-emacs-master
    repo_owner: djgoku
    repo_name: misemacs
    description: Hermetically-built relocatable Emacs.app for macOS — master channel
    version_prefix: "emacs-master-"
    version_source: github_tag
    asset: misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz
    ...
```

- [ ] **Step 4: Run the contract test to verify it passes**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/registry_contract_test.exs'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add aqua/registry.yaml orchestrator/test/orchestrator/registry_contract_test.exs
git commit -m "feat(versioning): resolve aqua versions from tags (version_source: github_tag)"
```

---

## Task 4: `pipeline/promote` — refuse `--latest` on a non-master tag

**Files:**
- Modify: `pipeline/promote` (insert a guard before the flip at the `>> [3] flip Latest` step)

- [ ] **Step 1: Add the guard**

In `pipeline/promote`, immediately before the existing flip line
`echo ">> [3] flip Latest marker to $TAG"`, insert:

```bash
# Master-only Latest policy: the repo-wide marker may only ever point at a master release.
# Independent of Core.Latest's selection — a bad latest_tag or manual mistake must not flip
# a non-master tag. (mise resolution is marker-independent via version_source: github_tag,
# so this guard protects only the human-facing badge.)
case "$TAG" in
  emacs-master-*) ;;
  *) echo "FATAL: refusing to flip Latest onto non-master tag '$TAG' (master-only policy)"; exit 1 ;;
esac

```

(The `>> [2] attach manifest` steps stay above it — attaching the manifest to any tag is
fine; only the `--latest` flip is master-restricted.)

- [ ] **Step 2: Verify the guard (negative) — refuses a non-master tag**

Run:
```bash
MISEMACS_PUBLISH_OK=1 bash pipeline/promote --repo djgoku/misemacs-phase5-lab \
  --tag emacs-31-2026-06-29 --manifest /dev/null 2>&1; echo "exit=$?"
```
Expected: prints `FATAL: refusing to flip Latest onto non-master tag 'emacs-31-2026-06-29' (master-only policy)` and `exit=1`. It must fail **before** any `gh release edit` (the `/dev/null` manifest also fails the `[ -f "$MANIFEST" ]` check, so confirm the FATAL line is the master-only one — reorder if needed by placing the guard immediately after arg parsing instead).

> Implementation note: if the manifest existence check fires first, move the `case "$TAG"`
> guard to just after the `[ -n "$REPO" ] && [ -n "$TAG" ]` usage check (line ~20) so the
> refusal is reached regardless of `--manifest`.

- [ ] **Step 3: Verify the guard (positive) — allows a master tag (dry, no real flip)**

Confirm a master tag passes the `case`. A full positive run would hit GitHub; instead
verify by inspection that `emacs-master-*` matches the first `case` arm (no FATAL). Optional
real check on the lab is in Task 6.

- [ ] **Step 4: Commit**

```bash
git add pipeline/promote
git commit -m "feat(versioning): promote refuses --latest on non-master tags"
```

---

## Task 5: README — document the consumer-facing behavior

**Files:**
- Modify: `README.org` (the install / channels section)

- [ ] **Step 1: Add/adjust the versioning + upgrade notes**

In the relevant install section of `README.org`, ensure the following points are present
(adapt wording to the surrounding prose; do not duplicate existing lines):

```org
Each channel updates independently. Install and follow a channel with =@latest=:

#+begin_src sh
mise use aqua:djgoku/misemacs-emacs-master@latest   # always the newest master build
mise use aqua:djgoku/misemacs-emacs-31@latest       # always the newest emacs-31 build
#+end_src

=mise use …@latest= writes =latest= to your =mise.toml=, so =mise upgrade= / =mise up= roll
you forward to the newest build automatically — *no =--bump= needed*. You only need
=mise upgrade --bump= if you pinned an exact dated version (e.g. =…@2026-06-29=).

Each channel resolves its own newest release; GitHub's "Latest" badge always points at the
newest =master= build and does not affect =emacs-31= (or any non-master) resolution.
```

- [ ] **Step 2: Note the maintainer `--cleanup-tag` caveat**

In the upstream/maintenance or "How it works" section, add:

```org
Note (maintainers): version resolution reads the Git *tag* list, so every tag must have a
matching Release with assets. The pipeline always creates tag+release together; when
removing a release, delete its tag too (=gh release delete <tag> --cleanup-tag=) so no
orphan tag shadows a newer one.
```

- [ ] **Step 3: Commit**

```bash
git add README.org
git commit -m "docs(versioning): per-channel @latest, no --bump, master-only Latest badge"
```

---

## Task 6: Full verification

- [ ] **Step 1: Lint + full test suite**

Run: `mise run lint && mise exec -- sh -c 'cd orchestrator && mix test --include macos --warnings-as-errors'`
Expected: format clean; all tests pass (new latest/finalize/contract cases included).

- [ ] **Step 2: Lab marker-independence check (optional, real)**

With a throwaway registry pointing at `djgoku/misemacs-phase5-lab` and
`version_source: github_tag` on the packages, force the GitHub Latest marker onto a
*non-newest* master release, then confirm:
```
mise latest aqua:<lab>-emacs-master   # => newest master tag, NOT the marker
mise latest aqua:<lab>-emacs-31        # => newest emacs-31 tag
```
(Restore the lab marker afterward.) This reproduces the spec's empirical proof end-to-end.

- [ ] **Step 3: Final commit (if any docs/log updates remain)**

```bash
git add -A && git commit -m "chore(versioning): validation notes" || true
```

---

## Notes / Out of Scope

- **Legacy dot/dash cutover** (real `djgoku/misemacs`): legacy dot-dated master tags would
  sort after dash tags under tag-list resolution. Resolve at cutover (delete legacy
  releases/tags, or switch new tags to dots). **Not part of this plan** (the lab is all-dash).
- `daily.yml` finalize job is unchanged: it already guards `if [ -z "$LATEST_TAG" ]` (so a
  non-master-only run simply skips the flip) and passes `--tag "$LATEST_TAG"` to promote
  (now always a master tag).
