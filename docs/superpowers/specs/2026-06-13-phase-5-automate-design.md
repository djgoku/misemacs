# Phase 5 — Automate: Design Spec

- **Date:** 2026-06-13
- **Status:** Draft for review
- **Umbrella spec:** `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` (§7 orchestrator brain + §7.2 state, §8 fingerprint + Decision E, §11.2 the 3-job CI shape, §12 risks, §14 Phase-5 row)
- **Builds on:** Phase 4 (merged to `main` at `1167d28`) — `mise run {build,relocate,package,publish,promote}` + `mix {release.names,release.manifest}` are the lab-proven primitives this phase **orchestrates**. The PURE decision core (`Core.{Hash,Detect,Tag,Decide,Latest}` + `Manifest`) already exists and is fixture-tested; Phase 5 wires it to real IO behind behaviours.
- **Evidence base:** §2 below. New facts validated this session (V1–V4) have fresh proofs; carried Phase-4 facts keep their P-numbers; the genuinely-new GitHub-Actions mechanics are an explicit **to-validate** list (T1–T10), not assumptions — per the repo's "validate, don't assume" rule.

## 1. Scope (the §14 Phase-5 row, resolved)

Phase 5 turns the manual Phase-4 pipeline into a **daily, change-gated GitHub Actions workflow** that produces `djgoku/misemacs`'s **first kept release** (Phase 4 deferred it via G2):

1. **`.github/workflows/daily.yml`** — the 3-job shape (§11.2): `decide` → `build` (matrix) → `finalize`, with triggers `schedule` (daily) / `workflow_dispatch(force_version)` / `pull_request(paths: versions/**, *.toml)`.
2. **`mix orchestrate.decide`** — the gate brain: IO edges (`Upstream` git-ls-remote, `Releases` gh-manifest-read, `Toolchain` CLT capture) → pure `Core.{Detect,Decide}` → a **dynamic matrix** + flags emitted as job outputs.
3. **`mix orchestrate.finalize`** — the cross-cell merge: prior `latest` manifest ∪ this-run fragments → `Core.Latest` picks the latest tag → reuse `pipeline/promote` to attach + flip (atomic, single-writer).
4. **`Upstream` + `Releases` read-adapters** behind behaviours (`Core.{Detect,Decide,Latest}` wired to real IO); fixture-tested core untouched.
5. **Decision E** — fold the macOS CLT/SDK fingerprint into `toolchain_hash`, captured identically by `decide` and the build cell's `release.manifest` (both on `macos-26`).
6. **CI caching** — ccache (content-addressed + restore-keys), pixi-env (exact key on `pixi.lock`), build-output (exact-key only); mise.lock left **on** (KB hang).
7. **Cutover** — `runner = macos-26` in `targets.toml`; **Phase 5 is finished and the full DoD proven on a throwaway repo**, then the proven branch is pushed to `djgoku/misemacs` (which stays untouched by all testing). `schedule` fires only from the default branch, so that one clean push *is* the activation — **cron enabled last** by construction, and the real repo's first run is production, not a test.
8. **Docs reconcile** — umbrella §8/§11/§13/§14, validation log, auto-memory, KB.

**Not in Phase 5:** a user-facing **README** (deferred by decision — A11); `emacs -nw` (umbrella §15 fast-follow); multi-version proof (Phase 6 — `emacs-30.x` by data only); native-comp / Linux / Developer-ID (umbrella §15). Multi-cell partial-failure and per-cell concurrency are *designed and wired* now but only exercised degenerately on v1's single cell (master × macos-arm64).

## 2. Starting state & evidence

### 2.1 Validated this session (with proof)

| # | Fact | Proof (2026-06-13) |
|---|---|---|
| V1 | **The real repo is pristine and the cutover already happened** — remote `djgoku/misemacs` `main` == local `1167d28` (the fresh take: `orchestrator/`, `pipeline/`, `versions.toml`, `.pregate/`, `aqua/registry.yaml` 993 B); **0 releases, 0 tags**; only `orchestrator-ci.yml`; **no README**. So both the (empty) throwaway and `djgoku/misemacs` exercise a *true* `first_run`; the real repo's first publish (its first fresh-take release) happens only after the fully-proven workflow is pushed up (A10). (Supersedes Phase-4 P10/P13 + the auto-memory "no remote; main = old system; legacy releases coexist".) | `gh api repos/djgoku/misemacs/{commits/main,contents,releases,tags,contents/.github/workflows,contents/README.md}` — main sha `1167d28`, `releases` count 0, `tags` count 0, `releases/latest` 404, `README.md` 404 |
| V2 | **Target is public ⇒ GitHub Actions (incl. macOS) is free.** Re-frames the §11.2 gate: its value is **latency + not cutting empty releases + good citizenship**, not $ — which is what makes a daily `macos-26` `decide` job affordable (A1/Decision E). | `gh repo view djgoku/misemacs --json visibility,isPrivate` → `PUBLIC`, `isPrivate=false` |
| V3 | **`macos-26` ("Tahoe") is GA-listed and the BARE label is arm64** (alias `macos-26-xlarge`); x64 is the explicit `macos-26-intel`/`-large`. Same convention as `macos-14`. ⇒ `runs-on: macos-26` yields the arm64 image; only `targets.toml`'s `runner` field changes. macOS 26 also matches the local host **and** the pregate VM base (`macos-tahoe-base`), tightening "green pregate = green CI". | `gh api repos/actions/runner-images/readme` table row "macOS 26 Arm64 \| arm64 \| `macos-26` or `macos-26-xlarge`"; `images/macos/macos-26-{,arm64-}Readme.md` present (→ KB github-actions.md) |
| V4 | **Decision-E source strings on a real Tahoe host** (the runner's will differ — to confirm on `macos-26`, T-Q4): `xcode-select -p` → a Developer dir path; `clang --version` → `Apple clang version 21.0.0 (clang-2100.1.1.101)` + an OS-volatile `Target: …darwin25.5.0` line; `xcrun --show-sdk-version` → `26.5`; CLT pkg `26.5.0.0.1777544298`. ⇒ the stable identity is the `clang-<build>` number + SDK version; the `Target:`/`InstalledDir` lines are host-OS/path noise to normalize out. | local probe, this host |

### 2.2 Carried from Phase 4 / the knowledge base (relied upon, already proven)

- **`gh release` semantics (P1–P6, P12, KB github-releases.md):** create-on-existing-**release** = exit 1 "already exists" (the `.N` retry signal); create-on-dangling-**tag** = silent adoption (snapshot must union tags ∪ release names); create without `--latest=false` **steals** the marker (always `--latest=false`; flip in finalize); `--clobber` for asset re-upload; `--cleanup-tag` for clean teardown.
- **aqua/mise consumption (P7–P9, KB mise.md):** `MISE_AQUA_REGISTRY_URL` → the in-repo `aqua/registry.yaml`; `@latest` = the GitHub latest-release **marker** (not sort); mise verifies GitHub's API digest, **not** `SHASUMS256.txt`; `{{.Arch}}` = `arm64`.
- **Empty-repo `releases/latest` recency fallback (Phase-4 2026-06-13 correction):** with **no** release flagged `make_latest`, `GET /releases/latest` returns the most-recent published release. So the first `--latest=false` publish *is* returned by `releases/latest` until finalize explicitly flips it — the real safety property is **incumbent preservation**, which on a pristine repo is vacuous (nothing to preserve) and then established by the first flip.
- **mise.lock in CI (KB mise.md):** leave the lockfile **on**; never set `MISE_LOCKFILE=false` workflow-wide (disables *reads* → `latest` re-resolves over the network → post-step hang). A cold-runner lock rewrite is harmless (no dirty-tree gate in the workflow).
- **bash 3.2 traps (KB bash.md):** `set -e` is off inside `$()` (explicit `|| return 1`); `echo|grep -q`+pipefail SIGPIPE; empty-array `"${arr[@]}"` under `set -u`. The reused `publish`/`promote`/`package` already encode these; new bash glue must too.
- **pregate = clean-VM proof (umbrella §11.3):** `.pregate/macos.sh` runs build→relocate→gate→cleanroom→package in one fresh `macos-tahoe-base` VM; green pregate predicts green CI **for the build path** by construction. ⇒ Phase 5's genuinely-new risk is the **decide-gate logic + GHA mechanics**, not the build.

### 2.3 To VALIDATE during implementation (the GHA mechanics — test, don't assume)

These are exercised on a **throwaway public repo** first (A10), each an explicit plan task:

| # | Must prove | How |
|---|---|---|
| T1 | `decide` emits `matrix={"include":[…]}` JSON that `strategy.matrix: ${{ fromJSON(needs.decide.outputs.matrix) }}` consumes; the **empty `include` ⇒ build job skipped** path; `if: needs.decide.outputs.any=='true'` as belt-and-suspenders | workflow_dispatch with a non-empty and an empty plan |
| T2 | Job outputs propagate (`decide.outputs.{matrix,any,dry_run}` via `needs`); the brace-bearing JSON survives the single-line `$GITHUB_OUTPUT` format | inspect downstream `needs` context |
| T3 | Per-cell `concurrency: build-${{matrix.name}}-${{matrix.target}}` lets distinct cells run in parallel yet serializes the *same* cell across runs; `finalize-latest` is a single writer | two overlapping dispatches |
| T4 | `schedule:` fires from the **default branch's** latest commit (so cron-last is the activation by construction) | a near-future cron tick on the throwaway, observed then reverted; plus GitHub docs |
| T5 | Per-cell **artifact fragments** up/download and aggregate across a matrix (matrix *job-outputs* collapse to one value — confirm artifacts are the right channel) | 1- and 2-cell synthetic matrix |
| T6 | `macos-26` is actually schedulable for djgoku's account (a GA-listed image can still be mid-rollout) | first dispatch errors immediately if not |
| T7 | ccache wraps the Emacs C compile under `pixi run` (warm-cache speedup); pixi-env cache restores the conda closure keyed on `pixi.lock`; build-output exact-key cache | timed cold vs warm cell |
| T8 | PR dry-run (build+package+upload-artifact, **no** release) and `workflow_dispatch(force_version)` (one ref, real publish) | a PR touching `versions/**`; a forced dispatch |
| T9 | **Idempotency** (§14 DoD: twice/day → 2nd releases nothing) and partial/zero-fragment finalize | two same-day real runs; a forced-fail cell |
| T10 | First-run live: `decide` reads no manifest → `first_run` → build → finalize writes the first manifest + flips the first `latest` | **on the throwaway** (the real repo's first run repeats it as production, post-cutover) |

## 3. Resolved decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| A1 | Decision-E runner-image fingerprint (`detect` vs CLT location) | **Run `decide` on `macos-26`** (not ubuntu), computing the same CLT-inclusive `toolchain_hash` the build cell records | The CLT only exists on a macOS runner; if `detect` (ubuntu) omitted it, its fingerprint would disagree with `release.manifest`'s **every run** → permanent "changed" → rebuild storm. Co-locating both on `macos-26` makes them agree by construction. The spec's "decide=ubuntu" was a **cost** play, moot on a free public repo (V2). Cost: quiet days = ~1 free macOS min vs 1 ubuntu min. (Alternatives B "manual `clt_pin`" and C "separate macOS probe job" rejected — B rots without a human bumping it; C adds a job + output hop for the same automatic result.) |
| A2 | Build matrix carries no tag | The `decide` matrix carries `{name,channel,ref,target,os,arch,runner}` only; the **tag is computed per-cell at publish** over a fresh snapshot (`Core.Tag`) | Matches `Decide.matrix/2`'s moduledoc + the `.N` retry-on-conflict contract; avoids a stale tag baked at decide-time racing a same-day rerun |
| A3 | finalize ownership (Fork 1 — D4 split) | **Elixir decides, bash writes:** `mix orchestrate.finalize` merges the manifest + selects latest (`Core.Latest`); the existing **`pipeline/promote`** does the `gh upload --clobber` + `edit --latest` | Honors D4 (merge/selection = decisions = Elixir; gh calls = glue = bash) and Phase-4 G3 (writes stay bash); reuses the lab-proven flip; no Elixir `Publisher` (the merge is the only new *decision*) |
| A4 | How finalize learns this run's tags (Fork 2) | **Per-cell artifact fragments:** each cell uploads its 1-version `build-manifest` entry; finalize downloads all → merges into the prior latest manifest | Artifacts aggregate cleanly across a matrix; matrix **job-outputs collapse** to a single value (GHA wart), so they can't carry N cells' tags. (Alt "re-discover via `gh release list` + date heuristics" rejected as fragile.) |
| A5 | Runner image | **`macos-26`** for `decide` and `build` (`targets.toml` `runner`); target name `macos-arm64`, os/arch, and all asset strings unchanged | V3: bare label = arm64; matches local host + pregate base (one macOS/SDK generation everywhere) |
| A6 | `latest` flip serialization | **`finalize` is the sole writer** of `latest` + the manifest, in a `concurrency: group: finalize-latest` (single writer); build cells **never** promote | Avoids N cells racing the marker; `.N` already serializes per-cell *publish* via the per-cell group |
| A7 | Triggers / dev workflow | `schedule` (daily) = detect-and-release; `workflow_dispatch(force_version)` = force one ref (real publish) or, if empty, run detect now; `pull_request(paths: versions/**, *.toml)` = **dry-run** (build+artifact, no release). **No `push` trigger** → merge-to-main never auto-releases; the next cron picks up the changed lock | Umbrella §11.2; fork PRs get a read-only token (can't publish) — dry-run is the correct ceiling for them |
| A8 | dry-run matrix scope (v1) | PR dry-run builds **all enabled versions** (v1 = just master), `dry_run=true`; no manifest comparison | One version today makes "changed-files scoping" needless complexity; Phase 6 can scope to git-diff-touched versions (noted seam) |
| A9 | Partial-failure / "due" tracking | **Implicit:** a failed cell publishes nothing → no fragment → finalize omits it → it stays unchanged-vs-(stale)-manifest → re-detected next run. Zero fragments ⇒ finalize no-ops (no flip) | No bespoke state; `fail-fast:false` lets good cells release |
| A10 | Validation strategy | **Finish Phase 5 entirely on a throwaway public repo, then push the proven branch to `djgoku/misemacs`.** Iterate AND prove the full DoD (T1–T10: complete first_run→build→finalize→flip→clean-VM-install cycle, twice/day idempotency, forced, partial-failure) on a fresh lab repo. `djgoku/misemacs` is **untouched by all testing**; its first run (post-push) is production. | User decision — keep the real repo clean. Faithful by construction: the workflow is repo-agnostic (`--repo`-parameterized; throwaway `aqua/registry.yaml` repo-name-swapped, Phase-4 style), so "green throwaway = green real" modulo the `MISEMACS_PUBLISH_OK` interlock + the identical cron tick. `act` rejected (imperfect matrix/concurrency/schedule fidelity). (Phase-4 lab was deleted; a new throwaway is needed.) |
| A11 | README / user docs | **Skip this phase.** Docs work = umbrella spec + validation-log + auto-memory + KB reconcile only | User decision; repo is pre-stable. The first automated release gives a future README something to point at |
| A12 | Guard rails carried | `publish`/`promote` keep G8 (`--repo` required; `djgoku/misemacs` needs `MISEMACS_PUBLISH_OK=1`); the workflow sets it in the real-repo job `env`. Every first real-repo mutation still gets a per-run courtesy heads-up | Standing constraint; the interlock makes "accidental real-repo publish" need two mistakes |

## 4. Design

### 4.1 `.github/workflows/daily.yml` — trigger surface & job graph

```yaml
on:
  schedule:        [{ cron: '0 7 * * *' }]      # daily; one fire; activated by the cutover push to main (A10)
  workflow_dispatch:
    inputs: { force_version: { type: string, required: false } }
  pull_request:
    paths: ['versions/**', '**/*.toml']         # dry-run only
permissions: { contents: read }                  # elevated to write per-job below
# No workflow-level concurrency: serialization lives at the right granularity on the jobs —
# per-cell `build-<name>-<target>` + single-writer `finalize-latest` (§4.3/§4.4). A workflow
# group would serialize whole runs and mask the per-cell behavior under test (T3).
jobs:
  decide:    # runs-on: macos-26  → outputs: matrix, any, dry_run
  build:     # needs: decide; if: any=='true'; runs-on: ${{ matrix.runner }}; strategy.matrix=fromJSON(matrix); fail-fast:false
  finalize:  # needs: [decide, build]; if: !cancelled() && dry_run!='true' && any=='true'; runs-on: ubuntu-latest; concurrency: finalize-latest
```

The workflow maps the **event** to a `decide` **mode**: `schedule`/empty-dispatch → `detect`; `workflow_dispatch` with `force_version` → `force`; `pull_request` → `dry-run`.

### 4.2 `decide` (job 1 — `mix orchestrate.decide`)

`runs-on: macos-26` (A1). Provision via `jdx/mise-action@v2` (`mise install` from `mise.toml`, cached). Then `mise run decide --repo <r> --date "$(date -u +%F)" --mode <detect|force|dry-run> [--force-version <name>]` writes `key=value` lines to **stdout**; the workflow step redirects them into `$GITHUB_OUTPUT` and a human summary into `$GITHUB_STEP_SUMMARY`.

**IO edges → pure core → IO edges:**

1. **Load manifests (pure read):** `Manifest.versions/1` → `[%{name,channel,ref}]` (for `plan`); `Manifest.jobs/2` → the full job list (for `matrix`). (`detect` & `force` use both; `dry-run` only needs jobs.)
2. **`detect` mode only — current state per version:**
   - `upstream_sha` = `Upstream.resolve(ref)` (§4.7) — `git ls-remote https://github.com/emacsmirror/emacs <ref>`; absent/unresolvable → `nil` (the `Detect` contract maps `nil` → `{false, :no_upstream}`, a skip — **never** a rebuild).
   - `toolchain_hash` = `Hash.toolchain_hash(mise.toml, mise.lock, clt)` where `clt = Toolchain.clt_fingerprint()` (Decision E, §4.5).
   - `inputs_hash` = `Hash.version_fingerprint(%{toolchain_hash, upstream_sha, mise_toml, pixi_toml, pixi_lock})` over the committed `versions/<name>/{mise.toml,pixi.toml,pixi.lock}`.
   - `last_manifest` = `Releases.last_manifest(repo)` (§4.7) — read the `latest` release's `build-manifest.json`; self-heal by scanning recent releases; **none ⇒ `nil`** (pristine repo today, V1).
   - `plan = Core.Decide.plan(versions, current_states, last_manifest, date)` → `%Plan{build, skip}`.
3. **`force` mode:** emit a single build entry for `--force-version` (reason `:forced`), bypassing detect — a pure `Decide.force/3`-style override (unit-tested), so the matrix is `[that version × its targets]`.
4. **`dry-run` mode:** `plan.build` = all enabled versions (A8); `dry_run=true`.
5. **Matrix + flags (pure):** `cells = Core.Decide.matrix(plan, jobs)`; emit
   - `matrix={"include": <cells>}` (Elixir `JSON.encode!`; one line),
   - `any=<cells != []>`,
   - `dry_run=<bool>`.
   When `any=false`: `matrix={"include":[]}` **and** `any=false` (T1 double-gate).

`decide` is otherwise pure over its IO inputs and fully ExUnit-testable by stubbing the three behaviours (`Upstream`/`Releases`/`Toolchain`) — the core algorithms (`Detect`/`Decide`) already are.

> **Minor race (acceptable):** `decide`'s `ls-remote` sha may be ~seconds behind the build cell's later checkout. Worst case the cell builds a 1-commit-newer `master` — still a valid, correctly-fingerprinted release (the manifest records the cell's checked-out sha, §4.3 step 4).

### 4.3 `build` (job 2 — the matrix)

`needs: decide`; `if: needs.decide.outputs.any == 'true'`; `runs-on: ${{ matrix.runner }}` (= `macos-26`); `strategy: { fail-fast: false, matrix: ${{ fromJSON(needs.decide.outputs.matrix) }} }`; `permissions: { contents: write }` (real path); per-cell `concurrency: { group: build-${{ matrix.name }}-${{ matrix.target }}, cancel-in-progress: false }` (A6 — serialize same cell, never cancel a build mid-flight; let it finish + publish, the rerun `.N`-collides and skips/bumps).

Per cell: checkout → `jdx/mise-action` → restore caches (§4.6) → then

- **Real path** (`dry_run=false`):
  1. `mise run build <name>` (`pipeline/build-emacs`) → `build/<name>/Emacs.app`.
  2. `mise run relocate` (Elixir relocate + deep ad-hoc sign + `verify_bundle` gate).
  3. `mise run publish --repo <repo> --version <name>` — snapshots tags ∪ releases, `mix release.names` computes the tag (`.N` on collision), `pipeline/package` builds the xattr-free tar + `SHASUMS256.txt` + self-verify, `gh release create … --latest=false` + assets, retry-on-`already exists`. **Phase-5 edit:** `publish` writes the resolved tag to `dist/<name>/published-tag.txt`.
  4. **Fragment:** `CLT=$(… Toolchain)`, `mix release.manifest --version <name> --tag "$(cat dist/<name>/published-tag.txt)" --upstream-sha "$(cat dist/<name>/upstream-sha.txt)" --clt-fingerprint "$CLT" --out fragment.json`; `actions/upload-artifact` (name `manifest-<name>-<target>`).
- **Dry-run path** (`dry_run=true`, PRs): steps 1–2, then `mix release.names --channel <ch> --date <date> --tags-file /dev/null` (empty snapshot → a clean tag) → `mise run package <name> <tag>` → `actions/upload-artifact` the **tarball** (for inspection). **No** `publish`, **no** fragment — fork PRs receive an auto read-only token and dry-run never publishes (A7).

Each successful real cell = one `--latest=false` release (tarball + `SHASUMS256.txt`) and one manifest fragment. No `latest` flip, no cross-version manifest yet — that's finalize.

### 4.4 `finalize` (job 3 — `mix orchestrate.finalize` + `promote`)

`needs: [decide, build]`; `if: ${{ !cancelled() && needs.decide.outputs.dry_run != 'true' && needs.decide.outputs.any == 'true' }}` (runs on **partial** build success too — `!cancelled()` covers the `failure` aggregate that `fail-fast:false` produces; A9); `runs-on: ubuntu-latest`; `permissions: { contents: write }`; `concurrency: { group: finalize-latest, cancel-in-progress: false }` (A6, single writer).

Steps: checkout → `jdx/mise-action` → `actions/download-artifact` (all `manifest-*` → `fragments/`) → then

1. `mise run finalize --repo <repo> --fragments fragments/ --out build-manifest.json` (`mix orchestrate.finalize`) — one Elixir step that reads, merges, and selects:
   - **Read prior state:** `Releases.last_manifest(repo)` → the current `latest` manifest (or `nil` on the pristine first run).
   - **Zero fragments ⇒ exit 0**, "nothing to finalize" (all cells failed/skipped; no flip).
   - **Merge:** `prior.versions ∪ {each fragment's single version}` (fragment entries win) via a pure `Manifest.merge/2`; write the merged schema-1 `build-manifest.json`.
   - **Latest selection:** order the built tags by release recency (oldest→newest) — v1 a single tag; multi by each fragment's `released_tag` + the release `createdAt` from `gh`. `Core.Latest.latest_target(built_tags)` → `{:set, tag}`. Print `latest_tag=<tag>`.
2. **Attach + flip (bash glue, A3):** `pipeline/promote --repo <repo> --tag <latest_tag> --manifest build-manifest.json` — **Phase-5 edit:** `promote` gains `--manifest <path>` to upload a **pre-built** (merged) manifest instead of recomputing a single-version one; still `gh release upload --clobber` then `gh release edit --latest` (idempotent + atomic + reversible, P3/P6).

On the pristine repo, run 1: prior=`nil` → merged = {master} → flip `emacs-master-<date>` to `latest` (the **first kept release + first latest flip + first manifest**, T10). Because `releases/latest` recency-returned that `--latest=false` release already (§2.2), the flip is confirming, not corrective.

### 4.5 Decision E — the CLT/SDK fingerprint

**What to capture (V4):** a labeled `Core.Hash.fingerprint` over the **stable** toolchain identity, normalizing out host-OS/path noise —
- `xcode-select -p` (Developer dir — distinguishes full-Xcode vs CLT-only and pinned paths),
- the `Apple clang version … (clang-<build>)` line of `clang --version` (drop the OS-volatile `Target:`/`InstalledDir`/`Thread model` lines),
- `xcrun --show-sdk-version`.

**Where it folds in:** `Core.Hash.toolchain_hash/2` → **`/3`** — `fingerprint([{"mise_toml",…},{"mise_lock",…},{"clt",clt}])`. Both consumers obtain `clt` via the shared `Orchestrator.Toolchain.clt_fingerprint/0` (IO behaviour) so they agree by construction: `mix orchestrate.decide` (detect) and the build cell's `mix release.manifest` (fragment). `release.manifest` gains `--clt-fingerprint <string>` (the cell passes the captured value; ubuntu unit tests pass a fixture). The pure `Hash` is fixture-tested; `Toolchain` has a `@tag :macos` real-capture test asserting **run-to-run stability** (Q4).

Changing the fingerprint formula is safe now: V1 (no surviving Phase-4 manifest; pristine repo) means run 1 is `first_run` regardless — there is nothing to mismatch.

### 4.6 Caching (umbrella §11.2)

- **ccache** — `actions/cache` key `ccache-${{ matrix.target }}-${{ hashFiles('versions/<name>/pixi.lock') }}-${{ github.sha }}`, restore-keys `…-<pixi.lock-hash>-` then `…-<target>-` (content-addressed ⇒ restore-from-prefix is safe). Set `CCACHE_DIR`; wire the Emacs compile through ccache under `pixi run` (`CC='ccache clang'` or a PATH shim). **VALIDATE it actually wraps the compile** (T7).
- **pixi-env** — `actions/cache` key `pixi-${{ matrix.target }}-${{ hashFiles('versions/<name>/pixi.lock') }}` (**exact**), path `versions/<name>/.pixi`; restores the locked conda closure (skip re-solve/-download).
- **build-output** — **exact-key only, no restore-keys** (avoid poisoning): key = the version `inputs_hash`; a hit short-circuits build+relocate. Marginal for daily-moving `master`; most valuable for a "due" re-publish and for Phase-6 pinned refs. Optional/last.
- **mise tool cache** — `jdx/mise-action` keyed on `mise.lock`. Lockfile stays **on**; **never** `MISE_LOCKFILE=false` (KB hang); a cold-runner rewrite is harmless (no dirty-tree gate in CI).

### 4.7 New & changed code surface

**New Elixir (behaviours + adapters, fixture-tested core untouched):**
- `Orchestrator.Upstream` — `@callback resolve(ref :: String.t()) :: String.t() | nil`; adapter `Upstream.GitLsRemote` (`git ls-remote https://github.com/emacsmirror/emacs <ref>`, parse the exact-ref sha, empty→`nil`).
- `Orchestrator.Releases` — `@callback last_manifest(repo :: String.t()) :: map() | nil`; adapter `Releases.Gh` (read `latest`'s `build-manifest.json` via `gh`; self-heal scan; none→`nil`).
- `Orchestrator.Toolchain` — `@callback clt_fingerprint() :: String.t()`; adapter runs the §4.5 commands.
- `Mix.Tasks.Orchestrate.Decide` (`mix orchestrate.decide`) and `Mix.Tasks.Orchestrate.Finalize` (`mix orchestrate.finalize`) — IO edges → pure core → stdout `key=value`.
- Pure helpers: `Manifest.versions/1` (the `[%{name,channel,ref}]` list), `Manifest.merge/2` (prior ∪ fragments), `Decide.force/3` (forced override).

**Changed:**
- `Core.Hash.toolchain_hash/2` → `/3` (add `clt`); all call sites updated.
- `Mix.Tasks.Release.Manifest` — `--clt-fingerprint` flag, folded into `toolchain_hash/3`.
- `pipeline/publish` — write `dist/<v>/published-tag.txt`.
- `pipeline/promote` — `--manifest <path>` (use a pre-built merged manifest; skip the self-compute).
- `targets.toml` — `runner = "macos-26"`.
- `mise.toml` — `[tasks.decide]`, `[tasks.finalize]` (thin `dir=orchestrator` wrappers; both demand `--repo`, so they can't fire accidentally).

**New:** `.github/workflows/daily.yml`.

### 4.8 Permissions & token

`permissions: contents: read` at workflow level; elevated to `write` only on `build` (real path) and `finalize`. `gh` uses `GH_TOKEN: ${{ github.token }}`. Fork PRs receive a read-only token → cannot publish, which is exactly the dry-run ceiling (A7). The real-repo `build`/`finalize` jobs set `env: MISEMACS_PUBLISH_OK: '1'` (G8 interlock).

## 5. Sequencing & validation gates

The whole of Phase 5 is **proven on a throwaway repo**; `djgoku/misemacs` is touched exactly once, at the end, by a clean cutover push (A10).

1. **Local / ExUnit (ubuntu-safe):** new behaviours stubbed; `Detect`/`Decide`/`Latest`/`merge`/`force` covered; `Hash.toolchain_hash/3` fixture-tested; `mise run test` green. (`:macos` `Toolchain` test runs in pregate / a macOS cell.)
2. **Throwaway public repo = where Phase 5 is finished (A10):** create a fresh lab repo (empty, public; its `aqua/registry.yaml` repo-name swapped, Phase-4 style); get the Phase-5 branch onto it (token-HTTPS push to the disposable repo — no signing needed). Drive the workflow there until the **entire DoD** holds:
   - **T1–T8** — dynamic matrix + empty-skip, job-output propagation, per-cell + `finalize-latest` concurrency (two overlapping dispatches), one observed cron tick (schedule-from-default), fragment up/download aggregation, caches, PR dry-run + `workflow_dispatch(force_version)`.
   - **T9/T10** — first_run→build→finalize→**first latest flip** on the empty throwaway; a **clean-VM `mise use aqua:<throwaway>@<tag>`** install of its own first release (the §14 consumer check); a **same-day second run that releases nothing** (idempotency); a forced-fail cell leaving its version "due".
   - Throwaway release/tag churn is free to be messy — it's disposable.
3. **Cutover (your push — one clean event):** push the finished, fully-proven branch to `djgoku/misemacs` `main` (`runner=macos-26`; the `build`/`finalize` jobs carry `MISEMACS_PUBLISH_OK=1`). No iterative testing ever lands on the real repo. Because `schedule` fires from `main` HEAD, this push **is** the cron activation (cron-last by construction).
4. **Real production go-live:** the first scheduled run (or a single confirming `workflow_dispatch`) on `djgoku/misemacs` is the repo's **first kept release** `emacs-master-<date>` + first manifest + first `latest` flip — production, not a test. A pristine-VM `mise use aqua:djgoku/misemacs@<tag>` confirms the real consumer path. Faithful by construction: same workflow/code as the throwaway, only `--repo` + the interlock differ.
5. **Cleanup:** delete the throwaway (user action — token lacks `delete_repo`). If the real go-live ever needs a redo, the Phase-4 path (`gh release delete <tag> --cleanup-tag`) restores pristine — but the throwaway proof makes that unlikely.

## 6. Error handling / failure modes

- **Nothing changed:** `any=false` → `build` skipped (empty matrix + `if`), `finalize` skipped. Quiet day = one `macos-26` `decide` (~1–2 min, free).
- **No upstream resolve:** `Upstream.resolve` → `nil` → `Detect` `:no_upstream` skip (never a rebuild).
- **Manifest missing/corrupt:** `Releases.last_manifest` self-heals (scan recent releases); truly none → `nil` → `first_run` (pristine repo today).
- **Tag collision (`.N`):** `publish` re-snapshots + recomputes + re-packages (P1); ≤3 then abort. Dangling tags counted via the tags ∪ releases union (P2) — no silent adoption.
- **Cell failure (partial):** `fail-fast:false` → other cells release; the failed cell emits no fragment → omitted from the manifest → re-detected "due" next run (A9). All-fail ⇒ zero fragments ⇒ finalize no-ops (no flip).
- **finalize flip fails after upload:** the manifest upload is `--clobber`-idempotent and precedes the flip; rerun finalize. Marker unmoved on an upload-ok/flip-failed intermediate (P3).
- **Real-repo interlock:** `--repo` required + `MISEMACS_PUBLISH_OK=1` ⇒ two independent mistakes needed to publish accidentally (G8/A12).

## 7. Docs reconcile (lands with the implementation branch)

- **Umbrella §8:** mark Decision E **wired** (CLT via `Toolchain` into `toolchain_hash/3`; both `decide` + `release.manifest` on `macos-26`).
- **Umbrella §11.2:** `decide` runs on **`macos-26`** (not ubuntu) — record the A1 rationale (free public Actions; CLT co-location avoids the rebuild storm).
- **Umbrella §13/§14:** move the Phase-5 GHA mechanics from "validated (brainstorm)" to **proved on the throwaway repo** (T1–T10 with run links); §14 Phase-5 row = done; note the real repo's **first kept release** landed at the cutover go-live.
- **`validation-log.md`:** a Phase-5 section (V1–V4 + T1–T10 results, lab + real, with commands/outputs).
- **Auto-memory `project-bundled-emacs-buildsystem`:** correct the stale state — **cutover done, remote = fresh take, repo pristine (0 releases/0 tags), public**; Phase 5 in progress/done.
- **KB:** `github-actions.md` (macos-26 = arm64, done) + any new dynamic-matrix/concurrency/job-output facts proven via T1–T5.

## 8. Approaches considered

- **A1 alternatives (Decision E):** **B** manual `clt_pin` in `targets.toml` (ubuntu-pure decide, deterministic, but rots without a human bump — and the maintainer doesn't track CLT); **C** ubuntu decide + a tiny `macos-26` probe job feeding `detect` (automatic, but an extra daily job + output hop). Chose **A** (decide on `macos-26`) — simplest automatic correctness, free on a public repo.
- **Fork 1 (finalize):** full Elixir `Publisher` wrapping the gh writes — rejected (re-implements lab-proven `promote`, deviates from G3; the only new *decision* is the merge, which is Elixir).
- **Fork 2 (tag aggregation):** re-discover this run's tags via `gh release list` + date heuristics — rejected as fragile vs artifact fragments.
- **Validation (A10):** `act` locally — rejected (imperfect matrix/concurrency/schedule fidelity → self-validating). Iterating on the real repo — rejected outright (user: keep `djgoku/misemacs` clean of *all* testing); the throwaway carries the full DoD proof, and the real repo's first run is production after one clean cutover push.
- **decide on ubuntu (spec literal):** rejected per A1.

## 9. Definition of Done

- [ ] `Upstream` + `Releases` + `Toolchain` behaviours & adapters; `mix orchestrate.{decide,finalize}`; `Manifest.{versions,merge}` + `Decide.force`; `Hash.toolchain_hash/3`; `release.manifest --clt-fingerprint`; `publish` tag-file + `promote --manifest`. `mise run test` green (ubuntu-safe; `:macos` Toolchain test in a macOS cell/pregate).
- [ ] `.github/workflows/daily.yml` (decide→build→finalize); the **entire DoD proved on the throwaway** — **T1–T10**: dynamic matrix + empty-skip, job-output propagation, per-cell + `finalize-latest` concurrency, one cron tick, fragment aggregation, caches, PR dry-run, forced dispatch, first_run→finalize→**first latest flip**, a clean-VM `mise use aqua:<throwaway>@<tag>` install, and **twice/day → 2nd releases nothing**.
- [ ] Decision E: `decide` and `release.manifest` compute **bit-identical** `toolchain_hash` on `macos-26`; CLT capture stable run-to-run (Q4).
- [ ] **Cutover:** the proven branch pushed to `djgoku/misemacs` `main` (`runner=macos-26`, `MISEMACS_PUBLISH_OK=1`) — the real repo's first production run is its **first kept release** + first manifest + first `latest` flip; pristine-VM `mise use aqua:djgoku/misemacs@<tag>` green; **cron live via the push**. No testing touched the real repo.
- [ ] Umbrella §8/§11/§13/§14 + validation-log + auto-memory + KB reconciled.
- [ ] Throwaway repo deleted (user action — token lacks `delete_repo`).

## 10. Phase 6 handoff

Phase 5 leaves the matrix, concurrency, partial-failure, and merge machinery **multi-version-ready** but exercised only on v1's single cell. Phase 6 ("prove trivial to add a version") adds `emacs-30.x` by **data only** (a `versions.toml` row + a `versions/<ref>/` dir): `Decide.matrix` fans it into a second build cell, `finalize`'s `Manifest.merge` + `Core.Latest` already handle N versions, and Decision-E's CLT fingerprint is what keeps a **pinned** ref rebuildable when the runner image bumps (the case where it's load-bearing). DoD: builds & releases with **zero stage/code change** — which includes **generating `aqua/registry.yaml` from `versions.toml`** (one `version_prefix` package per channel; Phase 5 hand-maintains the two packages, pinned by `registry_contract_test.exs`) so a new channel needs no registry edit. (`emacs -nw` remains the separate umbrella-§15 fast-follow.)
