# Design — marker-independent per-channel versioning + master-only Latest

> **SUPERSEDED (2026-06-29) by [`2026-06-29-per-channel-artifact-repos-design.md`](2026-06-29-per-channel-artifact-repos-design.md).**
> Do **not** implement this doc separately. The successor **keeps** the `version_source:
> github_tag` change (it provides per-channel marker-independence) but **drops** the master-only
> `Core.Latest` rewrite and the `promote` non-master guard — per-channel artifact repos remove the
> cross-channel Latest contention those parts addressed. None of this doc was ever implemented in
> code (docs-only), so there is nothing to revert; the successor builds from current code.

*2026-06-29. Branch: `enchant-task6`. Status: SUPERSEDED — see note above.*

## 1. Problem

misemacs publishes one GitHub release per channel per day (`emacs-master-<date>`,
`emacs-31-<date>`, `.N` on same-day collisions), consumed via mise's **aqua** backend
with one package per channel (`aqua:djgoku/misemacs-emacs-master`,
`…-emacs-31`), each using `version_prefix: "emacs-<channel>-"` so the version mise
compares is the bare date.

GitHub's **"Latest" marker is a single, repo-wide flag** — only one release in the whole
repo can hold it. Two problems follow:

1. **Non-master channels can never use it.** The marker (a master release) fails the
   `emacs-31-` prefix strip, so `…-emacs-31@latest` already resolves via aqua's
   tag-list fallback, not the marker.
2. **A stale/wrong marker poisons the matching channel.** With the current
   `version_source` (default `github_release`), mise *honors* the marker for a channel
   whenever the marked release matches that channel's prefix. Today
   `Orchestrator.Core.Latest.latest_target/1` picks `List.last(built_tags)` —
   **channel-agnostic** — so on a run where only `emacs-31` builds, an emacs-31 release
   would grab the marker; and a marker left on an old master makes `…-emacs-master@latest`
   resolve to the **stale** release.

## 2. Empirical findings (the basis for this design)

All verified against mise `2026.6.11` (source `v2026.6.14`) and the lab repo
`djgoku/misemacs-phase5-lab`:

- **mise honors the marker per matching channel** — with the marker forced onto the
  *older* `emacs-master-2026-06-25`, `mise latest …-emacs-master` returned `2026-06-25`,
  not the newest `2026-06-29`. (Confirms problem #2.)
- **A non-matching marker is ignored** — `…-emacs-31@latest` resolved to its newest
  (`2026-06-29.1`) while the marker sat on a master release.
- **`version_source: github_tag` ignores the marker entirely** — with the marker on the
  stale `2026-06-25`, `…-emacs-master@latest` resolved to the newest tag `2026-06-29`.
  Source: the `github_tag` fast-path returns `Ok(None)` and falls through to the tag
  list (`src/backend/aqua.rs:1759`), which is `version_prefix`-filtered then `list.last()`
  (`src/backend/mod.rs:3474`); GitHub's tags API returns descending-lexical order, so
  zero-padded ISO dates sort chronologically and `.1` collision suffixes sort newest.
- **Download + checksum + extract work under `github_tag`** with the full registry shape
  (`version_prefix` + `checksum: github_release/SHASUMS256.txt`): mise verifies via
  GitHub's per-asset **API digest** (`using GitHub API digest for checksum verification`),
  not the `SHASUMS256.txt` file — the `checksum:` block is harmless metadata for mise
  (it serves the standalone `aqua` CLI).
- **`latest` pin auto-rolls, no `--bump`** — `mise use …@latest` writes `= "latest"`
  (default `pin = false`); a `latest` pin re-resolves every `mise upgrade`
  (`src/toolset/tool_version.rs:394`, upgrade sets `latest_versions: true`). `--bump` is
  only needed when a user pins an exact dated version.

## 3. Goals / non-goals

**Goals**
- mise resolution is **marker-independent** for every channel (newest tag wins, per channel).
- The GitHub "Latest" badge is **always the newest `master`**, never a non-master channel
  (human-facing only — it no longer affects mise resolution).
- No change to the publish/asset contract; existing pinned consumers unaffected.

**Non-goals (explicitly out of scope here)**
- **Legacy dot/dash tag coexistence at the real-repo cutover.** The legacy system used
  dot-dated master tags (`emacs-master-2026.06.05`); `.` (0x2E) sorts after `-` (0x2D),
  so a leftover legacy tag would shadow new dash-dated releases under tag-list resolution.
  This is a **cutover** concern (delete legacy releases/tags, or switch new tags to dots);
  recorded here, handled separately. The lab is all-dash and unaffected.
- Changing the date format (dash → dot). Independent; not required by this change.

## 4. Design

### 4.1 Registry — decouple mise from the marker
`aqua/registry.yaml`: add `version_source: github_tag` to **both** packages
(`…-emacs-master`, `…-emacs-31`). Keep `type: github_release`, `version_prefix`, the
asset template, and the `checksum:` block unchanged. Effect: mise enumerates each
channel's versions from the **tag list** (prefix-filtered) and never consults the Latest
marker.

### 4.2 `Orchestrator.Core.Latest` — master-only selection (hardcoded)
Replace the channel-agnostic `List.last(built_tags)` with a master-only rule that stays
pure over the existing `built_tags` (list of tag strings):
- Filter `built_tags` to the master channel by the tag prefix
  `Naming.tag_base("master", "")` (= `"emacs-master-"`) — no new inputs needed, keeps the
  function's signature and "no IO" contract.
- Pick the newest matching tag (lexical max — zero-padded ISO dates sort chronologically,
  `.N` collisions sort newest; same ordering aqua relies on).
- Return `:unchanged` if no master tag was built this run (the marker stays on the previous
  master release, which still exists).

`"master"` is hardcoded as the sole Latest-eligible channel (per decision). Using
`Naming.tag_base` keeps the channel string in one place rather than a bare literal.

### 4.3 `finalize` / `promote`
- `Mix.Tasks.Orchestrate.Finalize` emits `latest_tag` = the master tag (or empty → no flip).
  `built_tags` (manifest-attach list) is unchanged.
- `pipeline/promote` flips Latest only to `latest_tag`. **Defensive guard:** `promote`
  hard-refuses `--latest` (exit non-zero) on any tag not matching `emacs-master-` —
  a second independent layer so a bad `latest_tag` or manual mistake can never mark a
  non-master release Latest.

### 4.4 Tests
- `latest_test.exs`: master built → its tag; emacs-31-only run → `:unchanged`;
  multi-master same-day → newest master tag.
- `registry_contract_test.exs`: assert `version_source: github_tag` is present on both
  packages (and the contract values still match `Naming`).
- A `finalize`/`promote` test for the non-master refusal guard.

### 4.5 Docs (README)
- Per-channel `@latest` resolves to each channel's newest release (marker-independent).
- `mise use …@latest` + `mise up` auto-roll forward (no `--bump`); `--bump` only for
  exact-date pins.
- master is the cosmetic GitHub "Latest" badge; non-master channels are installed by
  exact tag or `@latest`.
- The one `github_tag` caveat: a tag without a release will *resolve* but fail to
  download — our pipeline always creates tag+release together; when deleting releases use
  `gh release delete --cleanup-tag`.

## 5. Definition of Done
- `aqua/registry.yaml` has `version_source: github_tag` on both packages; `mise run test`
  green (incl. the contract + latest tests); registry contract test passes.
- A dry/lab check: with the marker forced onto a non-newest master, `…-emacs-master@latest`
  still resolves to the newest master tag (marker-independent), and `…-emacs-31@latest`
  to the newest emacs-31 tag.
- `pipeline/promote` refuses `--latest` on a non-master tag (negative test) and flips it
  on a master tag (positive).
- README updated.

## 6. Cutover note (for the eventual real-repo push, not this change)
Before relying on tag-list resolution on `djgoku/misemacs`, resolve the legacy dot-dated
master releases (delete them, or switch new tags to dots so they sort after) so a stale
legacy tag cannot shadow new releases. Also clear any leftover Latest marker on a
non-master/stale release.
