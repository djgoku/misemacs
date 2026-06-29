# Design — per-channel artifact repos (one source repo, N release buckets)

*2026-06-29. Branch: `enchant-task6`. Status: design — pending user review.*

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

### 1.1 Interaction with the marker-independent spec (regression it introduces)

`2026-06-29-marker-independent-versioning-design.md` (committed same day) switches **both**
packages to `version_source: github_tag`. The release API returns **creation-date-descending**
(channels interleave by recency), but the **tag** API returns **descending-lexical**, so all
`emacs-master-*` tags sort ahead of *all* `emacs-31-*` ahead of *all* `emacs-30-*`. Under
`github_tag` the starvation becomes **deterministic and total**: after ~100 daily master tags
(one page), the page is 100% master and the lower channels are unreachable. That spec's fix to the
"Latest" marker makes *this* problem worse. The present design **supersedes** it (see §4.8).

## 2. Empirical findings (the basis for this design)

Validated against mise source `v2026.6.14` (`src/github.rs`) and live read-only GitHub API
probes, 2026-06-29:

- **The list cap is one page of 100, on the combined list.** `list_releases_`
  (`src/github.rs:180`) and `list_tags_` (`:234`) both fetch `?per_page=100` and **stop after
  the first page**. They paginate further *only* if `MISE_LIST_ALL_VERSIONS` is set (users
  won't), or — releases only — when the entire first page is prereleases (bounded to 3 pages,
  `MAX_RELEASE_FALLBACK_PAGES`). The `version_prefix` filter runs *after* the fetch
  (`src/backend/mod.rs:3474`), so the 100-cap bites the raw cross-channel list.
- **Tag order is descending-lexical (confirmed live).** `GET /repos/djgoku/misemacs-phase5-lab/tags`
  returned all 18 `emacs-master-*` first, then `emacs-31-*` — never interleaved.
- **Release order is creation-date-descending** (source: releases API contract; the lab's
  releases are backfilled to identical timestamps so they're not a fair interleaving sample,
  but the code path is unambiguous).
- **The real repo has no release history to migrate.** `gh release list --repo djgoku/misemacs`
  → empty. This design lands **before the first real publish**, so there is no cutover of
  existing releases or the legacy dot-dated tags (those concerns from the marker spec §6
  evaporate — new releases go to brand-new repos).
- **The artifact repos do not exist yet** (`gh repo view djgoku/misemacs-emacs-{master,31}`
  → "Could not resolve") → a one-time bootstrap creates them.
- **`pipeline/publish` is already fully `--repo`-parameterized** — tag snapshot
  (`git ls-remote` + `gh release list` on `$REPO`), collision-recompute, and `gh release create`
  all target whatever `--repo` is passed. Publishing to a per-channel repo needs **no change to
  this script**.
- **The default `GITHUB_TOKEN` is scoped to the workflow's own repo only** (documented GitHub
  behavior) — it cannot create releases in a *different* repo. Cross-repo publish needs a PAT or
  GitHub App token (see §4.2). This is the one genuinely new operational cost.

## 3. Goals / non-goals

**Goals**
- Each channel's newest release is always discoverable/installable via `…@latest`, regardless of
  how many times other channels have built — i.e. no cross-channel crowding, ever.
- The developer edits exactly **one** repo (`djgoku/misemacs`): `versions.toml`, the
  `versions/<name>/` dirs, the orchestrator, CI. The per-channel repos are **write-only release
  buckets** that no human opens.
- `@latest` works per channel with **no** `version_source: github_tag` switch and **no**
  master-only-Latest logic — each repo's Latest marker is its own channel's newest.
- The publish/asset contract (tag shape `emacs-<channel>-<date>`, asset name, `version_prefix`)
  is **unchanged**; only the *host repo* of each release changes.

**Non-goals**
- Changing tag/date format, asset templates, or the per-channel `version_prefix` packages.
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

The channel→repo mapping is derived, not hand-listed: `repo = "djgoku/misemacs-emacs-#{channel}"`.
One place owns the convention (a helper in `Orchestrator.Naming`), so adding a channel needs no
new mapping entry.

### 4.2 Auth (Decision D1)

Cross-repo release creation/promotion needs a token with `contents:write` on the artifact repos.
Two standard options:

| Option | Setup | Ongoing |
|---|---|---|
| **GitHub App** + `actions/create-github-app-token` (recommended) | ~20 min, install on the artifact repos (or org-wide) | none — token minted per run |
| **Fine-grained PAT** as secret `MISEMACS_PUBLISH_TOKEN`, `contents:write` on the artifact repos | ~5 min | rotate ≤ yearly (PAT max expiry) |

**Recommendation: GitHub App**, because (a) no rotation, and (b) org-wide install means a *new*
artifact repo is writable with zero token edits — which is what makes "add a version = one PR"
(§4.7) fully hands-off. The PAT is the acceptable quick-start.

CI wiring: the `build` and `finalize` jobs set `GH_TOKEN` to the App/PAT token instead of
`${{ github.token }}`. The `decide` job, which only *reads* public release assets, keeps
`${{ github.token }}`.

### 4.3 Registry — repoint each package

`aqua/registry.yaml`: change each package's `repo_owner`/`repo_name` from `djgoku`/`misemacs`
to `djgoku`/`misemacs-emacs-<channel>`. Keep `type: github_release`, `version_prefix`, the asset
template, `checksum:`, and overrides unchanged. **Drop the `version_source: github_tag` line**
from the marker spec — with one channel per repo, the GitHub Latest marker is unambiguous and
`@latest` follows it correctly. When the planned "Phase 6: generate registry from versions.toml"
lands, the generator derives `repo_name` from the channel via the §4.1 helper.

### 4.4 Matrix carries the per-channel repo

`Orchestrator.Manifest.jobs/2` builds each matrix cell as
`{name, channel, ref, target, os, arch, runner}`. Add a derived `repo` field
(`"djgoku/misemacs-emacs-#{channel}"`). `Core.Decide.matrix/2` passes it through unchanged.
`daily.yml`'s publish step then uses `--repo "${{ matrix.repo }}"` instead of
`${{ github.repository }}`.

### 4.5 `publish` — no script change

`pipeline/publish --repo "${{ matrix.repo }}" --version <name> --channel <channel>` already does
the right thing against the per-channel repo: the tag snapshot reads that repo's tags+releases
(so collisions are now naturally per-channel), and `gh release create` lands there. The
`djgoku/misemacs` `MISEMACS_PUBLISH_OK` interlock (G8) no longer fires (target is an artifact
repo); an analogous guard can be added for the artifact repos if desired (Decision D2, §6).

### 4.6 `finalize` / `promote` / Latest — per-repo, simpler

Today: one `finalize` run reads the single merged manifest from `--repo`, picks one repo-wide
`latest_tag` (`Core.Latest.latest_target/1` = `List.last(built_tags)`), and `promote` flips that
one repo's Latest + attaches the merged manifest to every built tag.

New model — **each channel finalizes against its own repo**:
- `finalize` groups this run's fragments by channel and, per channel, calls
  `promote --repo djgoku/misemacs-emacs-<channel> --tag <that channel's newest tag>
  --manifest <that channel's manifest> --attach <that channel's built tags>`.
- Each repo's Latest = its channel's newest tag built this run (within a run a channel normally
  has one date ⇒ `--attach` is just that tag). `promote` already attaches + flips per `--repo`.
- **`Orchestrator.Core.Latest` and the marker spec's master-only-Latest rule + non-master refuse
  guard are removed** — there is no cross-channel Latest contention to arbitrate.

### 4.7 State store — per-channel manifest (Decision D3)

`build-manifest.json` is the cross-run state store: `decide` (detect mode) reads it from the
repo's **Latest release** to compare each version's `upstream_sha`/`inputs_hash`
(`Releases.Gh.last_manifest/1`). Splitting repos moves this store. Recommended:

- **M1 (per-channel manifest, recommended):** each artifact repo's Latest release carries its
  own channel's `build-manifest.json` (that channel's state only). `decide` reads N manifests
  (one per channel repo, via the existing repo-parameterized `last_manifest/1`) and assembles the
  combined detect state; `finalize` writes each channel's manifest to its own repo. Fully
  isolated; each repo self-describes. Cost: `decide` does N small `gh` fetches instead of 1.
- **M2 (single combined manifest kept on the source repo):** assets go to artifact repos but the
  one merged manifest stays on `djgoku/misemacs` (a dedicated state release or a committed file).
  Smaller orchestrator change, but the manifest lives apart from the releases it describes.

Recommend **M1** — it matches the "each repo self-describes its channel" principle and keeps the
`repo`-parameterized manifest functions doing one coherent thing.

### 4.8 Relationship to the marker-independent spec

This design **supersedes** `2026-06-29-marker-independent-versioning-design.md`. Adopting per-channel
repos means that spec's changes are **not implemented**: no `version_source: github_tag`, no
`Core.Latest` master-only rewrite, no `promote` non-master guard, no `registry_contract_test`
for `github_tag`. If that spec was already partially implemented on this branch, those changes
are reverted as part of this work. (Net: this design removes more code than it adds.)

### 4.9 Adding a new version (e.g. `emacs-30`), end to end

1. `versions.toml`: add `[versions.emacs-30]` (`ref` + `channel`). *(same as today)*
2. `versions/emacs-30/`: add `mise.toml` + `pixi.toml` + `pixi.lock`. *(same as today)*
3. Registry: add the `emacs-30` package pointing at `djgoku/misemacs-emacs-30` — or, with the
   Phase-6 generator, this is derived automatically. *(in-source)*
4. **Bootstrap the artifact repo** — either:
   - **Automated:** a CI guard step runs `gh repo create djgoku/misemacs-emacs-$CHANNEL --public
     2>/dev/null || true` before first publish (needs an org-scoped App/PAT), or
   - **Manual one-liner:** `gh repo create djgoku/misemacs-emacs-30 --public` (~10 s, once).

After the first push, `emacs-30` is fully automated forever (detect → build → publish →
finalize). With an org-wide App + the registry generator, steps 1–3 are the whole job: **one PR
touching only the source repo**, and CI creates the artifact repo on first run.

## 5. Definition of Done

- `aqua/registry.yaml`: both packages point at their artifact repos; no `version_source: github_tag`.
- `Manifest.jobs/2` emits `repo`; `daily.yml` publish + finalize use `matrix.repo` /
  per-channel repos; CI `GH_TOKEN` uses the chosen cross-repo token.
- `finalize`/`promote` flip Latest + attach the manifest **per artifact repo**; `Core.Latest`
  and the marker spec's master-only logic are removed.
- `mise run test` green (incl. updated decide/finalize/manifest tests for the `repo` field and
  per-channel finalize); the marker-spec's `github_tag` contract test is deleted.
- A lab check on per-channel repos (e.g. `djgoku/misemacs-lab-emacs-master` +
  `…-emacs-31`): after publishing both, `…-emacs-master@latest` and `…-emacs-31@latest` each
  resolve to their own newest release, and neither is affected by the other's volume.
- README updated: per-channel `aqua:` packages now live in per-channel repos; `@latest` rolls
  each channel independently; adding a version = the §4.9 flow.

## 6. Open decisions (for the user / spec review)

- **D1 — cross-repo token:** GitHub App (recommended) vs fine-grained PAT (§4.2).
- **D2 — artifact-repo publish interlock:** add a `MISEMACS_PUBLISH_OK`-style guard for the
  artifact repos, or rely on the token scope alone? (The G8 guard exists to prevent *accidental*
  real-repo publishes; with dedicated buckets the risk is lower.)
- **D3 — state store:** M1 per-channel manifest (recommended) vs M2 single combined manifest on
  the source repo (§4.7).
- **D4 — bootstrap:** automate `gh repo create` in CI (needs repo-create scope) vs a one-time
  manual `gh repo create` per new channel (§4.9 step 4).
