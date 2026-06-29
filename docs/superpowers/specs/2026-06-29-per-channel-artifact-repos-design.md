# Design — per-channel artifact repos (one source repo, N release buckets)

*2026-06-29. Branch: `enchant-task6`. Status: design — revised after Codex review (keeps
`github_tag`; adds preflight + failure-mode handling). Pending user review.*

## 1. Problem

misemacs publishes every channel (`master`, `emacs-31`, future `emacs-30`, …) as GitHub
releases in **one repo** (`djgoku/misemacs`), consumed via mise's aqua backend with one
package per channel (`aqua:djgoku/misemacs-emacs-master`, `…-emacs-31`), each stripping its
`emacs-<channel>-` tag prefix so the compared version is a bare CalVer date.

mise lists a repo's versions from a **single capped page** of the GitHub tag (or release)
API and *then* applies the per-channel `version_prefix` filter. Because the cap is applied to
the **combined, all-channels list**, a high-frequency channel crowds the low-frequency ones
out of the window:

- `master` builds ~daily; `emacs-31`/`emacs-30` are release branches that change rarely.
- Once `master` accrues more tags/releases than the cap, the **newest `emacs-31`/`emacs-30`
  fall off the fetched page** → `…-emacs-31@latest` / `…-emacs-30@latest` silently resolve to
  **nothing**, even though those releases exist.

A user therefore can't discover or install the lower channels. With separate repos this can't
happen — each repo's list contains exactly one channel, so its newest is always at the top.

### 1.1 Why this composes with `version_source: github_tag` (kept)

`2026-06-29-marker-independent-versioning-design.md` (committed same day) switched **both**
packages to `version_source: github_tag` so `@latest` resolves to the newest *tag* (sort-based)
and is **independent of the repo-wide GitHub "Latest" marker** — which a failed/stale promote
can otherwise leave pointing at the wrong release.

`github_tag` and per-channel repos solve **orthogonal** problems and we keep both:

- The tag API returns **descending-lexical**, so all `emacs-master-*` tags sort ahead of *all*
  `emacs-31-*`. In a *single* combined repo `github_tag` makes crowding **deterministic and
  total** (after ~100 daily master tags the page is 100% master). **Per-channel repos remove
  that** — each repo lists one channel, so its newest is always first, and the cap only ever
  ages out *that channel's* old dated tags (still installable by exact tag).
- `github_tag` keeps **`@latest` marker-independent within each channel.** So a run that
  publishes successfully but fails at finalize/promote (Latest not flipped) **still** resolves
  `@latest` to the new release — the resilience the marker spec bought, retained.

Net: per-channel repos make `github_tag` *safe to keep* (no crowding) while `github_tag` makes
the per-repo Latest marker **cosmetic** (a human-facing badge, not a resolution input). This
design therefore **narrows** the marker spec rather than superseding it (see §4.9).

## 2. Empirical findings (the basis for this design)

Validated against mise source `v2026.6.14` (`src/github.rs`) and live read-only GitHub API
probes, 2026-06-29:

- **The list cap is one page of 100, on the combined list.** `list_releases_`
  (`src/github.rs:180`) and `list_tags_` (`:234`) both fetch `?per_page=100` and **stop after
  the first page**. They paginate further *only* if `MISE_LIST_ALL_VERSIONS` is set (users
  won't), or — releases only — when the entire first page is prereleases (bounded to 3 pages,
  `MAX_RELEASE_FALLBACK_PAGES`). The `version_prefix` filter runs *after* the fetch
  (`src/backend/mod.rs:3474`), so the 100-cap bites the raw cross-channel list. *(Permalink the
  exact `v2026.6.14` lines in the implementation plan so this doesn't rest on a manual read; a
  lab probe in §5 re-confirms it end-to-end.)*
- **Tag order is descending-lexical (confirmed live).** `GET /repos/djgoku/misemacs-phase5-lab/tags`
  returned all 18 `emacs-master-*` first, then `emacs-31-*` — never interleaved.
- **Release order is creation-date-descending** (source: releases API contract; the lab's
  releases are backfilled to identical timestamps so they're not a fair interleaving sample,
  but the code path is unambiguous).
- **The real repo has no release history to migrate.** `gh release list --repo djgoku/misemacs`
  → empty. This design lands **before the first real publish**, so there is no cutover of
  existing releases or the legacy dot-dated tags (those concerns from the marker spec §6
  evaporate — new releases go to brand-new repos with no prior tags to audit).
- **The artifact repos do not exist yet** (`gh repo view djgoku/misemacs-emacs-{master,31}`
  → "Could not resolve") → a one-time bootstrap creates them (§4.10).
- **`pipeline/publish` is already fully `--repo`-parameterized** — tag snapshot
  (`git ls-remote` + `gh release list` on `$REPO`), collision-recompute, and `gh release create`
  all target whatever `--repo` is passed. Publishing to a per-channel repo needs **no change to
  this script's repo plumbing** (only the §4.5 derived-name assertion is added).
- **The default `GITHUB_TOKEN` is scoped to the workflow's own repo only** (documented GitHub
  behavior) — it cannot create releases in a *different* repo. Cross-repo publish needs the
  GitHub App token (see §4.2). This is the one genuinely new operational cost.

## 3. Goals / non-goals

**Goals**
- Each channel's newest release is always discoverable/installable via `…@latest`, regardless of
  how many times other channels have built — i.e. no cross-channel crowding, ever.
- The developer edits exactly **one** repo (`djgoku/misemacs`): `versions.toml`, the
  `versions/<name>/` dirs, the orchestrator, CI. The per-channel repos are **write-only release
  buckets** that no human opens.
- `@latest` stays **marker-independent per channel** (via `github_tag`), so a publish that
  succeeds but whose finalize/promote fails still resolves to the new release.
- The publish/asset contract (tag shape `emacs-<channel>-<date>`, asset name, `version_prefix`,
  `version_source: github_tag`) is **unchanged**; only the *host repo* of each release changes.

**Non-goals**
- Changing tag/date format, asset templates, the per-channel `version_prefix` packages, or the
  `github_tag` source.
- Migrating existing releases (there are none on the real repo — §2).
- Multi-arch/OS expansion (orthogonal; `targets.toml` is untouched).

## 4. Design

### 4.1 Repo topology + naming

- **Source repo** (unchanged): `djgoku/misemacs` — all code, config, CI, and the per-channel
  `build-manifest.json` reads/writes are driven from here.
- **Artifact repos** (new, one per channel): `djgoku/misemacs-emacs-<channel>` —
  `…-emacs-master`, `…-emacs-31`, `…-emacs-30`, … Each holds only its channel's releases+tags.
- The aqua package name already equals `<owner>/<repo>` for the artifact repo
  (`aqua:djgoku/misemacs-emacs-master`), so the registry change in §4.3 is just repointing
  `repo_owner`/`repo_name` — the user-facing `aqua:` string does not change.

The channel→repo mapping is **a single derived helper** — `Naming.artifact_repo(channel)` →
`"djgoku/misemacs-emacs-#{channel}"` (owner configurable). One function owns the convention; the
matrix (§4.4), the registry generator (§4.3), and the publish/promote guard (§4.5) all call it,
so adding a channel needs no new mapping entry and there is one place to test.

### 4.2 Auth — GitHub App (D1: decided), minted just-in-time

Cross-repo release creation/promotion needs a token with `contents:write` on the artifact repos.
**Decision: a GitHub App** (via `actions/create-github-app-token`), installed on the
`misemacs-emacs-*` artifact repos with **`contents: write`** permission. No PAT, no rotation.

The App is installed **only on the artifact repos** with **contents-only** permission — not
org-wide and not repo-administration — consistent with D4 (manual repo creation, §4.10) and D2
(token scope is the sole publish boundary, §4.5).

**Token minted just-in-time (review fix).** The build job does many minutes of work (build,
stage-enchant, relocate, cleanroom, package) *before* it publishes; an installation token lives
~1 h, so minting at job start risks expiry mid-job. Mint the token in a step **immediately
before** `pipeline/publish` (and again before the finalize/promote step), scoped to that
channel's repo (`repositories: misemacs-emacs-<channel>` where the action supports it; otherwise
the App's install set). The `decide` job only *reads* public release assets → keeps
`${{ github.token }}`.

### 4.3 Registry — repoint each package (keep `github_tag`)

`aqua/registry.yaml`: change each package's `repo_owner`/`repo_name` from `djgoku`/`misemacs`
to `djgoku`/`misemacs-emacs-<channel>`. **Keep** `type: github_release`, `version_source:
github_tag`, `version_prefix`, the asset template, `checksum:`, and overrides unchanged. When the
planned "Phase 6: generate registry from versions.toml" lands, the generator derives `repo_name`
from the channel via `Naming.artifact_repo/1` (§4.1).

### 4.4 Matrix carries the per-channel repo

`Orchestrator.Manifest.jobs/2` builds each matrix cell as
`{name, channel, ref, target, os, arch, runner}` and has **no `repo` field today**. Add a derived
`repo` (= `Naming.artifact_repo(channel)`). `Core.Decide.matrix/2` filters/passes cells through
unchanged, so `repo` rides along. `daily.yml`'s publish + finalize steps then use
`--repo "${{ matrix.repo }}"` instead of `${{ github.repository }}`.

### 4.5 `publish` — repo plumbing unchanged, add a derived-name assertion

`pipeline/publish --repo "${{ matrix.repo }}" --version <name> --channel <channel>` already
targets the per-channel repo correctly (snapshot reads that repo's tags+releases → collisions are
now naturally per-channel; `gh release create` lands there).

The `djgoku/misemacs` `MISEMACS_PUBLISH_OK` interlock (G8) no longer fires (target is an artifact
repo). Per **D2** there is **no replacement env interlock** — the App's contents-only,
artifact-repo-scoped install is the publish boundary. **But** add a cheap **derived-name
assertion** (distinct from the D2 env guard): `publish` and `promote` refuse to run unless
`--repo == Naming.artifact_repo(--channel)`. This catches a malformed matrix cell (wrong/empty
`repo`) *before* `gh release create`, turning a silent wrong-repo publish into a loud preflight
failure. It is data validation, not an authorization gate.

### 4.6 `finalize` / `promote` / Latest — per-repo

Today: one `finalize` run reads the single merged manifest from `--repo`, picks one repo-wide
`latest_tag` (`Core.Latest.latest_target/1` = `List.last(built_tags)`), and `promote` flips that
one repo's Latest + attaches the merged manifest to every built tag. Fragments today carry only
per-version entries with `released_tag` — **no channel/repo field**.

New model — **each channel finalizes against its own repo**:

- **Fragment shape gains `channel` + `repo`.** `mix release.manifest` (per build cell) stamps the
  channel and `Naming.artifact_repo(channel)` into the fragment so `finalize` can group without
  re-deriving from tag strings.
- **`finalize` groups fragments by repo** and, per repo, writes that channel's manifest and calls
  `promote --repo <channel-repo> --tag <that channel's newest tag> --manifest <that channel's
  manifest> --attach <that channel's built tags>`.
- **Per-channel latest selector replaces `Core.Latest`.** `Core.Latest.latest_target/1`
  (repo-wide `List.last`) and the marker spec's master-only rule + non-master refuse guard are
  **removed**; in their place a small pure selector picks each channel's newest tag from its own
  fragments. `Orchestrate.finalize_outputs/3` is reshaped to emit a per-channel
  `{repo, latest_tag, manifest, attach_tags}` list rather than one tuple. This is a *replacement*,
  not a deletion (the call site in `Orchestrate` depends on it).
- **The Latest flip is now cosmetic** (a human-facing GitHub badge): resolution is `github_tag`
  (§1.1), so a failed flip does **not** strand `@latest`. The manifest **attach** is the part
  that matters (it is the state store, §4.7).
- **Partial multi-repo finalize is rerun-safe and isolated.** Promote uploads the manifest
  (`--clobber`, idempotent) then flips Latest; both are idempotent per repo. If repo A succeeds
  and repo B fails, re-running finalize re-promotes both cleanly. To bound blast radius, the
  finalize job runs **per channel** (a `finalize-<repo>` matrix with `concurrency:
  finalize-${repo}`) so one channel's failure neither blocks nor half-updates another, and a
  rerun is per-channel obvious. A channel is only marked done once its manifest attach **and**
  Latest flip return success.

### 4.7 State store — per-channel manifest (D3: decided — M1), read by tag-sort

`build-manifest.json` is the cross-run state store: `decide` (detect mode) compares each
version's `upstream_sha`/`inputs_hash` against the prior manifest (`Releases.Gh.last_manifest/1`).
Splitting repos moves this store.

**Decision: M1 — per-channel manifest.** Each artifact repo carries its own channel's
`build-manifest.json` (that channel's state only). `decide` reads N manifests (one per channel
repo, via the repo-parameterized `last_manifest/1` over `Naming.artifact_repo/1`) and assembles
the combined detect state; `finalize` writes each channel's manifest to its own repo.

Two refinements from review:

1. **Read the manifest from the newest release by tag-sort, not the "Latest" marker.**
   `last_manifest/1` today fetches from the repo's Latest *marker* release. Since resolution is
   `github_tag` and the marker is now cosmetic (§4.6), the state read must use the **same
   sort-newest tag** to avoid coupling state to a marker a failed promote may have left stale.
   `last_manifest/1` is changed to: list the repo's tags (sort-newest, prefix-filtered) → fetch
   `build-manifest.json` from that release.
2. **Distinguish empty-repo from error (review fix).** Today `last_manifest/1` returns `nil` on
   *any* failure — release-not-found, auth error, network error, corrupt JSON — and `nil` is also
   the legitimate "first run, nothing built yet" signal (`Detect.changed?` → `:first_run`). M1
   multiplies this risk across N repos. The function must return a **three-way** result:
   `{:ok, manifest}` | `{:empty, repo}` (repo reachable, no releases yet → genuine first-run) |
   `{:error, reason}` (auth/network/parse failure → **abort the run loudly**, never silently
   treat as first-run and rebuild/over-skip). `decide` maps `:empty → :first_run`, `:error →`
   non-zero exit with the repo + reason.

(Rejected alternative M2 kept one combined manifest on `djgoku/misemacs`; it avoids N reads but
puts the state apart from the releases it describes and was declined in D3.)

### 4.8 Preflight & failure modes

A short, explicit preflight (run inside `decide`, before emitting the matrix) and the
failure-mode contract:

- **Per channel, assert the artifact repo is reachable.** Using the §4.7 three-way result:
  `:ok`/`:empty` → proceed (`:empty` = first run); `:error` → **fail the run** with
  `<repo>: <reason>` (an unreachable/misconfigured repo or missing App install must not masquerade
  as a first-run build). This converts Codex's "decide silently treats unreadable repos as
  first-run, then publish fails later" into a single early, clear failure.
- **First-publish ordering.** The artifact repo + App install + registry entry must exist before
  the first publish for a channel (§4.10). If they don't, the preflight (`:error`) fails the run
  before any build work — not deep inside `pipeline/publish`.
- **A channel that never built.** Until a channel's first successful publish its artifact repo is
  empty, so `…-emacs-<channel>@latest` resolves to nothing. This is expected and bounded: the
  registry entry is only added (or the channel only announced) once the first build lands.
  Document in the README that a freshly-added channel has no installable version until its first
  daily build publishes; `Detect.changed?` will build it on the next upstream change or via a
  one-shot `force_version`.
- **Partial finalize / token expiry mid-run** — covered by §4.6 (per-channel idempotent rerun)
  and §4.2 (just-in-time token).

### 4.9 Relationship to the marker-independent spec (narrows, not supersedes)

This design **keeps** the marker spec's core change — `version_source: github_tag` on both
packages (§4.3) — because it provides per-channel marker-independence that per-channel repos do
*not* (§1.1). What it **removes** from the marker spec are the parts made unnecessary by
per-channel repos:

- `Orchestrator.Core.Latest`'s master-only rewrite → **replaced** by the per-channel latest
  selector (§4.6), not deleted-and-forgotten.
- `promote`'s non-master `--latest` refuse guard → unnecessary (no cross-channel Latest
  contention); the §4.5 derived-name assertion covers the data-validation intent instead.
- The "master is the sole Latest-eligible channel" framing → moot; every repo has its own Latest.

The `registry_contract_test` is **kept and updated** to assert `version_source: github_tag` *and*
the per-channel `repo_owner`/`repo_name`. If the marker spec was partially implemented on this
branch, only the master-only `Core.Latest`/guard parts are reworked; the `github_tag` registry
change stays.

### 4.10 Adding a new version (e.g. `emacs-30`), end to end

1. `versions.toml`: add `[versions.emacs-30]` (`ref` + `channel`). *(same as today)*
2. `versions/emacs-30/`: add `mise.toml` + `pixi.toml` + `pixi.lock`. *(same as today)*
3. Registry: add the `emacs-30` package pointing at `djgoku/misemacs-emacs-30` (keep
   `github_tag`) — or, with the Phase-6 generator, derived automatically via
   `Naming.artifact_repo/1`. *(in-source)*
4. **Bootstrap the artifact repo (D4: decided — manual):** run `gh repo create
   djgoku/misemacs-emacs-30 --public` once (~10 s), then install the GitHub App on it. CI does
   **not** create repos — keeping the App's permission to contents-only (least privilege). If the
   repo/App/registry aren't in place, the §4.8 preflight fails the next run loudly (and it
   re-runs cleanly once they exist).

After that one-time setup, `emacs-30` is fully automated forever (detect → build → publish →
finalize). Recurring per-version work is steps 1–3 (one PR touching only the source repo) plus
the single `gh repo create` + App-install in step 4.

## 5. Definition of Done

- `Naming.artifact_repo/1` exists with tests; `aqua/registry.yaml` both packages point at their
  artifact repos and **retain `version_source: github_tag`**.
- `Manifest.jobs/2` emits `repo`; `daily.yml` publish + per-channel finalize use `matrix.repo`;
  the App token is minted **just before** publish and before promote.
- `publish`/`promote` assert `--repo == Naming.artifact_repo(--channel)` (negative test for a
  mismatched repo).
- `release.manifest` fragments carry `channel` + `repo`; `finalize` groups by repo and writes a
  per-channel manifest; `Core.Latest` is replaced by a per-channel latest selector (unit-tested:
  single channel, multi-channel run, same-day multi-tag).
- `last_manifest/1` reads from the **sort-newest** release and returns the three-way
  `:ok`/`:empty`/`:error`; `decide` preflight fails loudly on `:error` and treats `:empty` as
  first-run (tests for all three).
- `mise run test` green (incl. the updated decide/finalize/manifest/registry-contract tests).
- A lab check on per-channel repos (e.g. `djgoku/misemacs-lab-emacs-master` + `…-emacs-31`):
  after publishing both, `…-emacs-master@latest` and `…-emacs-31@latest` each resolve to their
  own newest release; neither is affected by the other's volume; and a simulated
  publish-succeeds/finalize-fails (Latest not flipped) still resolves `@latest` to the new tag.
- README updated: per-channel `aqua:` packages live in per-channel repos; `@latest` rolls each
  channel independently and is marker-independent; a freshly-added channel has no installable
  version until its first publish; adding a version = the §4.10 flow.

## 6. Decisions (resolved 2026-06-29)

- **D1 — cross-repo token: GitHub App** (`actions/create-github-app-token`), contents-only,
  installed on the artifact repos, **minted just-in-time** before publish/promote. (§4.2)
- **D2 — artifact-repo publish interlock: no env guard.** The App scope is the authorization
  boundary; a non-auth **derived-name assertion** (`--repo == Naming.artifact_repo(--channel)`) is
  added separately as data validation. (§4.5)
- **D3 — state store: M1**, per-channel `build-manifest.json`, read from the **sort-newest**
  release with a three-way `:ok`/`:empty`/`:error` result. (§4.7)
- **D4 — bootstrap: one-time manual** `gh repo create` + App-install per new channel; CI does not
  create repos (least privilege). (§4.10)
- **D5 — keep `version_source: github_tag`** (this revision). Per-channel repos and `github_tag`
  are orthogonal: repos kill crowding, `github_tag` keeps `@latest` marker-independent so a failed
  finalize/promote can't strand it. The Latest marker becomes cosmetic. (§1.1, §4.3, §4.9)

### Review points incorporated (Codex, 2026-06-29)

App-token just-in-time minting (§4.2); derived-name assertion (§4.5); fragment `channel`/`repo`
field + per-channel latest selector replacing `Core.Latest` + per-channel finalize matrix (§4.6);
state read by tag-sort + three-way `:ok`/`:empty`/`:error` (§4.7); preflight & failure modes,
incl. channel-that-never-built and first-publish ordering (§4.8); keep `github_tag` and update
(not delete) the registry-contract test (§4.9, D5). Deferred to the implementation plan: exact
`create-github-app-token` inputs and the source permalink for the mise pagination lines.
