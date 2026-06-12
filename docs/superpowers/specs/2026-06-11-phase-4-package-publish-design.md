# Phase 4 — Package + Publish: Design Spec

- **Date:** 2026-06-11
- **Status:** Draft for review
- **Umbrella spec:** `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` (§7.2, §10, §11.1, §13, §14)
- **Builds on:** Phase 3 (merged to `main` at `fd19970`) — `mise run build` → `mise run relocate` already yields a relocated, deep-ad-hoc-signed, `verify_bundle`-gated `Emacs.app` (a transport-proven 150 MB artifact sits reusable in the phase-3 worktrees).
- **Evidence base:** §2 below; full publish-mechanics proofs recorded 2026-06-11 in
  `docs/superpowers/validation-log.md` (Phase 4 section) and the knowledge base
  (`~/.claude/knowledge-base/{github-releases,mise}.md`). Lab = throwaway repo
  `djgoku/misemacs-phase4-lab` (real repo untouched by all validation).

## 1. Scope (the §14 Phase-4 row, resolved)

Phase 4 ships the path from `build/master/Emacs.app` to "a stranger's clean Mac
runs it via `mise use aqua:djgoku/misemacs@<tag>`":

1. **Vendored consumer registry** — `aqua/registry.yaml` committed to this repo
   (§4.1) + a contract test binding it to `Orchestrator.Naming`.
2. **`mix release.names` + `mix release.manifest`** — thin, network-free CLI
   wrappers over `Core.Tag`/`Naming` and `Core.Hash` (§4.2–4.3).
3. **`pipeline/package`** — layout check → xattr-free tar → `SHASUMS256.txt` →
   local transport self-verification (§4.4).
4. **`pipeline/publish`** — fresh tag snapshot → names → package →
   `gh release create --latest=false` + assets, with `.N` collision retry (§4.5).
5. **`pipeline/promote`** — `build-manifest.json` attach + `--latest` flip
   (§4.6). **Exercised lab-only in Phase 4** (G2).
6. **Clean-box E2E** — `scripts/e2e-aqua-install.sh` inside a fresh pregate VM:
   lab dress rehearsal → approved real-repo run → approved cleanup (§4.7, §5).
7. **Docs reconcile** — umbrella spec deltas, validation log, knowledge base (§7).

**Not in Phase 4:** decide/finalize automation, `Releases`/`Publisher`
behaviours, cron/dynamic matrix (Phase 5); byte-reproducible tarballs (deferred,
G4/P11); `-nw` (§15 fast-follow); Developer ID (Decision F stands); updating the
`djgoku/aqua-registry` fork branch (the consumed registry is the in-repo one, P7).

## 2. Evidence (validated 2026-06-11 against the lab repo; gh 2.92.0, mise 2026.6.1)

| # | Fact | Proof (lab unless noted) |
|---|---|---|
| P1 | `gh release create` on an existing **release** → **exit 1**, stderr `a release with the same tag name already exists: <tag>` (closes the §13 open question; this is the `.N` retry signal) | identical re-create failed exit 1 with exactly that message |
| P2 | `gh release create` on an existing **tag with no release** → exit 0, silently adopts the tag (release attaches to whatever commit the tag points at); `gh release delete` without flags keeps the tag | delete → tag still in `ls-remote` → re-create succeeded |
| P3 | A release created with **no `--latest` flag steals the Latest marker** (GitHub defaults `make_latest=true`); `--latest=false` preserves the incumbent; `gh release edit <tag> --latest` flips it afterwards | dash-tag release auto-became latest; `--latest=false` left the incumbent; edit flipped it back |
| P4 | **Draft releases create no git tag** (URL `untagged-…`) and are invisible unauthenticated → aqua/mise can never resolve or install a draft | `ls-remote` shows no tag; unauth `/releases` omits it |
| P5 | **Prereleases** create the real tag, are publicly visible, never auto-latest — and are **excluded from `mise ls-remote`** yet installable by exact `@tag` | created one: tagged + public + not latest; absent from `ls-remote`, exact-tag install OK |
| P6 | Re-uploading an existing asset name → exit 1 unless `--clobber` | upload twice, then with `--clobber` |
| P7 | The consumption mechanism is **`MISE_AQUA_REGISTRY_URL` → a raw single-file registry**: `djgoku/misemacs@main:aqua/registry.yaml` (old-system README). mise parses it and matches `aqua:<owner>/<repo>` against `repo_owner`/`repo_name`. Full chain validated: template render, download, extract, layout, **`{{.Arch}}` = `arm64`** (closes the Phase-0 Naming canary) | lab registry → `mise install …@emacs-master-2026-06-02` succeeded into the contractual layout; without the env var: `no aqua-registry found` |
| P8 | **`@latest` = GitHub's latest-release *marker*** (`releases/latest`, via the mise-versions proxy with direct fallback) — **not** version sort. Dot- and dash-tags coexist harmlessly; the flip is atomic. (Gotcha: `MISE_CACHE_DIR` is separate from `MISE_DATA_DIR`; a warm cache serves a stale `latest` for its TTL.) | marker on dot-tag → dot; marker flipped to dash → dash (fresh data **and** cache dirs) |
| P9 | **mise does not verify `SHASUMS256.txt`** (2026.6.1): install succeeded with a deliberately corrupted checksum file; mise verifies **GitHub's API per-asset digest** instead (`using GitHub API digest for checksum verification`). The file remains required by the registry contract (real `aqua` CLI enforces it when enabled) + as the audit artifact | corrupt SHASUMS → install ok; debug log shows the API-digest path, no SHASUMS fetch |
| P10 | Legacy releases use dot-tags (`emacs-master-2026.06.05` is the current Latest) and carry `build-manifest.org` — **never `build-manifest.json`** → the new system's first run lands in the designed `first_run` base case (§7.2/§8) | live `djgoku/misemacs` release list + asset inventory |
| P11 | Tarball bytes are **stable for a given built tree** (re-tar 1.1 s apart → identical sha256) and **differ across rebuilds** (fresh mtimes) → reproducible-bytes engineering would buy nothing v1 ships | local probe, three archives |
| P12 | `gh release delete <tag> --yes --cleanup-tag` removes **release and tag** in one command (exit 0) — the validated real-repo cleanup path | post-design check: tag gone from `ls-remote`, release gone from API |
| P13 | The fresh take has **no git remote**; `djgoku/misemacs` main still serves the old system. `gh --repo` publishes from anywhere; release-created tags point at the remote default-branch HEAD until the cutover push (cosmetic — the tag is an artifact handle, §11.1) | `git remote -v` empty; old README fetched from main |
| P14 | The proven `SHASUMS256.txt` format is `shasum -a 256` output (`<hex>  <asset>`, two-space separator), listing the tarball only | legacy 2026.06.03 asset (the release installed on this machine) |

## 3. Resolved decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| G1 | Latest marker | `publish` **always** passes `--latest=false`; flipping latest is `promote`'s job, never implicit | P3: GitHub steals the marker by default — the one outward-facing surprise this design must make impossible |
| G2 | Real-repo E2E lifecycle | publish (approved) → clean-VM validate → **cleanup** (approved, `--cleanup-tag`). Phase 4 leaves `djgoku/misemacs` byte-identical to before; the first *kept* release, first latest flip, and first manifest attach on the real repo arrive with Phase-5 automation | User decision 2026-06-11; P12 validates the mechanism; legacy `@latest` users can never observe Phase 4 |
| G3 | Elixir scope | Names + manifest as network-free mix wrappers; **all `gh` IO stays in bash**. `Releases`/`Publisher` behaviours wait for Phase 5 | D4 split; adapters designed when their consumer (decide/finalize) is concrete |
| G4 | Determinism | Defer byte-reproducibility. Keep `COPYFILE_DISABLE=1 tar --no-xattrs` (E7/§10) | P11: nothing consumes it; rebuilds differ anyway |
| G5 | Registry vendoring | Commit `aqua/registry.yaml` (contract-equivalent to the served one); contract test asserts `Naming` ↔ file agreement via line-presence checks (no YAML dep) | P7: the consumed URL points into this repo on main — the cutover push must not break installs |
| G6 | Checksums | `package` self-verifies (`shasum -c`) before any network call | P9: the installer won't catch a bad SHASUMS — we must |
| G7 | Lab repo | `djgoku/misemacs-phase4-lab` stays alive through Phase-4 implementation (dress rehearsals), then the user deletes it (token lacks `delete_repo`) | Rehearsal target with zero real-repo risk |
| G8 | Guard rails | `publish`/`promote`/cleanup require an explicit `--repo`; targeting `djgoku/misemacs` additionally requires `MISEMACS_PUBLISH_OK=1`; every real-repo mutation gets per-run user approval | Standing constraint: real-repo release/tag changes need explicit go-ahead each time |

## 4. Design

### 4.1 Vendored registry + contract test

`aqua/registry.yaml` — verbatim copy of what
`raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml` serves today
(P7; the shape proven in production by this machine's own installs — the
fork-branch variant differs only in YAML structure, not contract): asset template `misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz`, format
`tar.gz`, `darwin: macos`, checksum `SHASUMS256.txt`/sha256/`github_release`,
`supported_envs: darwin/arm64`, and the four `files:` entries under
`{{.AssetWithoutExt}}/Emacs.app/Contents/MacOS/…`. The existing
`naming_test.exs` contract test gains a section that reads this file and asserts
the template line, checksum asset line, replacement line, and all four `src:`
paths appear verbatim and agree with `Naming.asset_name/3`,
`Naming.checksums_filename/0`, and `Naming.bundle_binaries/0` (string/regex
checks — no YAML dependency). Drift in either direction breaks the suite.

### 4.2 `mix release.names` (pure wrapper)

```
mix release.names --channel master --date 2026-06-11 --os macos --arch arm64 \
                  --tags-file -          # newline-separated tag snapshot on stdin (or a path)
→ stdout:  tag=emacs-master-2026-06-11
           asset=misemacs-emacs-master-2026-06-11-macos-arm64.tar.gz
           stem=misemacs-emacs-master-2026-06-11-macos-arm64
           checksums=SHASUMS256.txt
```

Tag via `Core.Tag.next_tag/3` (`.N` from the snapshot — the retry-on-conflict
contract in its moduledoc is now exercised for real); names via `Naming`. The
caller supplies the date (`date -u +%F`) and the snapshot — the task stays pure
over its inputs and fully ExUnit-testable (`Mix.Task.rerun/2` + `capture_io`).

### 4.3 `mix release.manifest` (thin IO edge, no network)

```
mix release.manifest --version master --tag <tag> --upstream-sha <sha> --out build-manifest.json
```

Reads exactly the §8 fingerprint inputs — repo `mise.toml` + `mise.lock`
(`toolchain_hash`) and `Manifest.version_input_files("master")` — computes
`inputs_hash` via `Core.Hash`, and emits the schema-1 JSON (§7.2) with Elixir's
built-in `JSON`. Using `Core.Hash` here guarantees Phase 5's `detect-changes`
recomputes bit-identical fingerprints; a hand-written manifest would risk a
permanent "changed" verdict. `--upstream-sha` comes from the package stage —
the sha actually built, recorded from `build/<version>/src` (§4.4 step 7).

### 4.4 `pipeline/package <version> <tag>` (bash, `build-emacs` conventions)

1. **Preconditions:** `build/<version>/Emacs.app` exists (relocated + signed —
   `relocate` already ran `verify_bundle`, the build-time-only deep verify, E7).
2. **Layout check (never move):** every `Naming.bundle_binaries/0` path exists
   and is executable (Phase 3 validated `make install` already emits
   `Contents/MacOS/bin/{emacsclient,etags,ebrowse}`); fail loudly otherwise.
   **Nothing mutates the bundle after sign+verify.**
3. **Stage:** `dist/<version>/stage/<stem>/Emacs.app` via APFS clone
   (`cp -c -R`, fallback `cp -Rp`) — `<stem>` from `release.names`.
4. **Tar:** `COPYFILE_DISABLE=1 tar --no-xattrs -czf <asset> -C stage <stem>`
   (spec §10 bullet; the xattr-borne pdmp/rcs2log signatures die in transport
   anyway — E7 — and xattr-free archives are clean for Linux-guest tooling).
5. **Checksums:** `shasum -a 256 <asset> > SHASUMS256.txt` (P14 format).
6. **Self-verify (all local, before any gh call):** `shasum -c`; `tar -tzf`
   asserts the stem prefix + all four binaries; extract to a temp dir and run
   the **transport smoke** — `Emacs --batch` version print + per-Mach-O
   `codesign --verify --strict` on the Phase-3 sentinels
   (`Contents/Frameworks/libgnutls.30.dylib`, `Contents/MacOS/bin/emacsclient`)
   + assert zero `com.apple.cs.*`/quarantine surprises in the extracted tree.
   This is the E7-correct packaged-artifact check (bundle-level deep verify is
   build-time-only and already happened in `relocate`).
7. **Record:** `dist/<version>/upstream-sha.txt` from
   `git -C build/<version>/src rev-parse HEAD` (input to `release.manifest`).

Output dir: `dist/<version>/` (gitignored): `<asset>`, `SHASUMS256.txt`,
`upstream-sha.txt`. Pregate's macOS recipe appends `mise run package` with a
sentinel tag (e.g. `pregate-smoke`) so layout/packaging regressions are caught
in the same fresh VM that builds — packaging is seconds, no new VM machinery.

### 4.5 `pipeline/publish` (bash; the only stage that writes to GitHub)

```
pipeline/publish --repo <owner/repo> [--version master]
```

1. **Guard rails (G8):** `--repo` required; `djgoku/misemacs` additionally
   requires `MISEMACS_PUBLISH_OK=1`.
2. **Tag snapshot:** `git ls-remote --tags <repo>` ∪ `gh release list`
   tag-names. (Union because P2 shows dangling tags get adopted — they must
   count as taken so a half-failed prior run yields `.N+1`, not adoption — and
   release names are the actual collision surface, P1.)
3. `mix release.names` → `tag`, `asset`, `stem`.
4. `pipeline/package <version> <tag>`.
5. `gh release create <tag> --repo <repo> --title <tag> --latest=false
   --notes "<channel> @ <upstream-sha>"` + `<asset>` + `SHASUMS256.txt`.
6. **Collision retry (≤3):** on exit 1 + the P1 message, re-snapshot, recompute
   (`.N`), **re-package** (the stem embeds the tag), retry. Any other failure
   aborts loudly; a partial release (created but assets incomplete) is cleaned
   up by the operator (`gh release delete`) and re-run — simplest correct v1.

No `build-manifest.json` at create time — that is `promote`'s payload (G1/G2).

### 4.6 `pipeline/promote` (bash; lab-only in Phase 4)

```
pipeline/promote --repo <owner/repo> --tag <tag> [--version master]
```

`mix release.manifest` (upstream sha from `dist/`) → `gh release upload <tag>
build-manifest.json --clobber` → `gh release edit <tag> --latest`. Atomic and
reversible (P3). Same G8 guard rails. Phase 4 proves it on the lab repo so
Phase 5 only has to schedule it; the real repo's first promote is Phase 5's
first kept release.

### 4.7 Clean-box E2E — `scripts/e2e-aqua-install.sh` (pregate VM)

Runs **inside** a fresh macOS VM via the Phase-3 `pregate --cmd` pattern (guest
network + in-guest `mise` are proven by every pregate run; the GUI smoke worked
in-guest in Phase 3):

```
MISE_AQUA_REGISTRY_URL=<raw registry url>  +  fresh MISE_DATA_DIR/MISE_CACHE_DIR
mise use aqua:<owner>/<repo>@<tag>             # the §14 DoD invocation, verbatim
Emacs --batch --eval '(princ emacs-version)'   # bundle resolves its closure
GUI frame smoke (best-effort)                  # NS path
codesign --verify --strict on the two sentinel Mach-O files (E7-correct check)
find <install> … com.apple.quarantine → must be zero (E1 invariant holds via aqua)
```

- **Lab run:** registry URL = the lab repo's raw `main/aqua/registry.yaml`
  (`repo_owner/repo_name` point at the lab), tarball = the **real 150 MB
  artifact** published by our own `publish` — the full-fidelity dress rehearsal.
- **Real run:** registry URL = the real consumed URL (P7 — today it still
  serves the old-system file, whose contract is identical), package =
  `aqua:djgoku/misemacs@<tag>`. Passing this **is** the §14 DoD.

### 4.8 mise tasks

`[tasks.package]`, `[tasks.publish]`, `[tasks.promote]`, `[tasks.e2e]` — thin
wrappers over the pipeline scripts (same one-definition seam as build/relocate;
`publish`/`promote` still demand `--repo` + interlock env, so `mise run publish`
cannot fire accidentally).

## 5. Sequencing & approval gates

1. **Local:** `package` self-verify green against the existing relocated app
   (reused from the phase-3 worktree — no rebuild).
2. **Lab dress rehearsal:** `publish --repo djgoku/misemacs-phase4-lab` (real
   artifact) → VM E2E vs lab → `promote` vs lab → re-resolve `@latest` flips to
   the promoted tag (P8). Zero real-repo risk.
3. **GATE (user):** `publish --repo djgoku/misemacs` (`--latest=false`; legacy
   `emacs-master-2026.06.05` keeps `@latest`, P3/P8 — invisible to users).
4. **Real E2E:** VM `mise use aqua:djgoku/misemacs@<tag>` green → **§14 DoD
   met** (recorded in the validation log with outputs).
5. **GATE (user):** cleanup — `gh release delete <tag> --yes --cleanup-tag`
   (P12); verify tag gone, release gone, Latest still `emacs-master-2026.06.05`.
   Real repo ends byte-identical to its Phase-3 state (G2).
6. Failure at step 4: the same approved cleanup, then fix and repeat from 3.

## 6. Error handling

- All `package` failures (layout, checksum, transport smoke) abort **before any
  network call**; everything under `dist/` is regenerable.
- `publish`: the P1 collision is the one retryable error (fresh snapshot +
  recompute per the `Core.Tag` contract); everything else aborts loudly.
- `promote`/cleanup are single-mutation steps — a failure leaves the previous
  state (marker unmoved / release intact) and is rerun after diagnosis.
- The G8 interlock + explicit `--repo` make "accidentally published to the real
  repo" require two independent mistakes.

## 7. Docs reconcile (lands with the implementation branch, Phase-3 style)

- **Umbrella §10:** add the vendored-registry bullet (the consumed registry
  lives at `aqua/registry.yaml` in-repo; `MISE_AQUA_REGISTRY_URL` is the
  documented install mechanism) + note that mise verifies the GitHub API digest,
  not `SHASUMS256.txt` (P9) — the file stays for the aqua contract + audit.
- **Umbrella §13:** move to validated — `gh release create` exit behavior (P1/
  P2), aqua `{{.Arch}}`=`arm64` (P7, closes the `Naming` ARCH NOTE canary +
  its `naming_test` comment), `@latest` marker semantics (P8), first-run base
  case confirmed live (P10).
- **Umbrella §14 Phase-4 row:** DoD met via validated-then-cleaned release (G2);
  first kept release moves to Phase 5's first automated run.
- **Umbrella §7.2:** note P10 (legacy `latest` carries no `build-manifest.json`
  → first automated run is `first_run` by construction).
- **`validation-log.md`:** Phase 4 section (P1–P14 with commands/outputs; lab
  + real E2E results appended during implementation).
- **Knowledge base:** `github-releases.md` (new: P1–P6, P12), `mise.md`
  (aqua-backend facts: P7–P9 + cache gotcha), `index.md` pointers. (Written at
  brainstorm time — already durable.)

## 8. Approaches considered

- **A. Bash package/publish + names-only mix wrappers (chosen, G3).** Matches
  D4 (bash glue / Elixir decisions); smallest new surface; every gh behavior it
  relies on is lab-validated.
- **B. Full `Releases`/`Publisher` behaviours in Elixir now.** Rejected:
  front-loads Phase-5 adapter design before decide/finalize requirements are
  concrete; more to test with no Phase-4 payoff.
- **C. Real-repo validation via draft or prerelease.** Rejected: drafts are
  un-installable (P4 — no tag, invisible); prereleases work by exact tag (P5)
  but add a state flip for no benefit over `--latest=false` + cleanup (G2),
  since `@latest` is marker-driven either way (P8).
- **D. Reproducible tarballs now.** Rejected (G4/P11): nothing consumes
  byte-identity; rebuilt Mach-Os differ regardless; xattr-free is the part that
  matters (E7) and is kept.

## 9. Definition of Done

- [ ] `aqua/registry.yaml` vendored; contract test binds it to `Naming`
      (asset template, checksums name, four binary paths); suite green.
- [ ] `mix release.names` / `mix release.manifest` + ExUnit coverage (ubuntu-safe;
      `:macos` untouched); `mise run test` green.
- [ ] `pipeline/package` self-verify green locally against the existing
      relocated app (layout check, xattr-free tar, `shasum -c`, extract smoke:
      `--batch` + sentinel Mach-O verifies); pregate macOS recipe runs it.
- [ ] Lab rehearsal green end-to-end: `publish` → VM E2E (`mise use
      aqua:djgoku/misemacs-phase4-lab@<tag>`) → `promote` → `@latest` flip
      observed.
- [ ] **Real repo (each step user-approved):** `publish --latest=false` → VM
      E2E `mise use aqua:djgoku/misemacs@<tag>` runs + sentinel sigs verify +
      zero quarantine (**the §14 DoD**) → cleanup via `--cleanup-tag`; Latest
      still `emacs-master-2026.06.05`; repo state unchanged.
- [ ] Umbrella spec reconciled (§7.2, §10, §13, §14) + validation-log Phase 4
      section complete; `Naming`'s ARCH-NOTE canary comment resolved.
- [ ] Lab repo deleted (user action — token lacks `delete_repo`) once Phase 4
      merges.

## 10. Phase 5 handoff

Ready-made for automation: `promote` is the finalize primitive (manifest attach
+ latest flip, lab-proven); `release.names`/`release.manifest` are the CLI seams
decide/finalize call; the P1 exit-1 message is the machine-checkable `.N` retry
signal; the snapshot rule (tags ∪ release names) is specified; P10 fixes the
first automated run's base case. Phase 5 keeps its first real release — and
performs the real repo's first promote.
