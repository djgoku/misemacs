# Bundled Emacs Build & Release System — Design Spec

- **Date:** 2026-06-05
- **Status:** Draft for review
- **Publishes to:** `djgoku/misemacs` (GitHub Releases)
- **Consumed by:** existing aqua registry `djgoku/aqua-registry@feat/djgoku/misemacs` → `mise use aqua:...`

## 1. Goal

Build self-contained, **relocatable Emacs** from `emacsmirror/emacs` for multiple
versions/refs, publish them as GitHub Releases on a **daily cadence that only
releases when something actually changed**, and make each build installable via
mise/aqua. Adding a new Emacs version must be a **data change, never a code change**.

This is a *fresh take* — the existing `djgoku/misemacs` repo contents are not used
as a reference; we publish releases there but rewrite the approach.

## 2. Scope

**v1 (first end-to-end release):**

- One version: `master`.
- One target: **macOS arm64**.
- **native-comp disabled** (no `libgccjit`).
- **Ad-hoc code signing** (not Developer ID / notarization).
- Full pipeline: detect-change → build → relocate → sign → package → publish →
  installable via `mise use aqua:djgoku/misemacs@<tag>`.

**Designed-for, NOT built in v1 (see §13):** native-comp, Linux + more arches,
precompiled elisp packages (vterm/pdf-tools/tree-sitter grammars), Developer ID +
notarization, per-channel `latest` aliases.

## 3. Resolved decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Artifact | Relocatable, self-contained `Emacs.app` (Linux equivalent later) | User goal; works offline with no system/Homebrew/pixi deps |
| D2 | native-comp | **Disabled** for v1 | Avoids `libgccjit` bundling; large simplification |
| D3 | v1 targets | **macOS arm64 only** | Start single, validate end-to-end, extend trivially |
| D4 | Orchestration brain | **Elixir** (pure decision fns) + **mise** (input locking) + **bash** (glue) | mise has no cross-run memory → wrong tool for change detection; keep its strength, put decisions in testable Elixir |
| D5 | Signing | **Ad-hoc, signed last** (Developer ID deferred) | **Assumed sufficient** — existing `djgoku/misemacs` releases already install on other Macs; optionally double-validate in Phase 3. Relocation invalidates sigs ⇒ sign last regardless |
| D6 | Release target repo | **`djgoku/misemacs`** | Existing aqua registry already points here; zero registry edits |
| D7 | Reproducibility | **Pixi project** (`pixi.toml` + committed `pixi.lock`) for C libs, activated via `mise-env-pixi` | `pixi.lock` locks the full transitive closure; closes mise/conda's transitive-lock gap |
| D8 | Dep sourcing order | **mise registry → aqua → pixi/conda** (pixi via the mise pixi plugins, local-first) | Pipeline toolchain via registry/aqua (locked in `mise.lock`); Emacs C libs via the pixi project (locked in `pixi.lock`) |

## 4. Architecture overview

A **manifest** defines the build matrix; a **pipeline of small, file-coupled
stages** does the work; an **Elixir brain** makes all decisions; **GitHub Actions**
runs it with a cheap gate in front of expensive macOS runners.

```
 cron (daily) / workflow_dispatch / PR
        │
        ▼
  ┌──────────────┐  changeset.json   ┌───────────────┐
  │ detect-changes│ ────────────────▶│ gate: any?    │ no → STOP (no release)
  │ (Elixir core) │  per-ref changed? └───────────────┘
  └──────────────┘                          │ changed refs only (dynamic matrix)
                                            ▼
                  fetch-source → build-emacs → bundle-relocate → sign
                                                                  │
                                            package → publish ◀───┘
                                                │
                                  GitHub Release on djgoku/misemacs
                                                │
                                  aqua registry → mise use aqua:... → user
```

## 5. Repo layout

```
misemacs/                              # this repo's fresh contents (publishes to djgoku/misemacs)
├── versions.toml                      # THE manifest: one entry per ref. Single source of truth.
├── targets.toml                       # OS×arch matrix (v1: macos-arm64 only)
├── versions/
│   └── master/
│       ├── mise.toml                  # per-version env: EMACS_REF, configure flags, pixi-env wiring
│       ├── pixi.toml                  # build deps (conda-forge) for this ref
│       └── pixi.lock                  # FULL transitive lock (committed)
├── orchestrator/                      # Elixir mix project (ExUnit-tested)
│   ├── mix.exs                        # dep: {:toml, "~> 0.7"} (manifest parsing)
│   ├── lib/                           # Naming + PURE Core.{Hash,Detect,Tag,Decide,Latest} + Manifest
│   ├── lib/mix/tasks/orchestrate.ex   # entry Mix task: IO edges → pure Core → IO (Phase 5)
│   └── test/                          # ExUnit over fixtures (no real builds/releases)
├── pipeline/                          # stages — each standalone & fixture-testable
│   ├── fetch-source
│   ├── build-emacs
│   ├── (relocate → orchestrator)      # relocation crux → Elixir Orchestrator.Relocate + `mix relocate` (Phase 2; not bash)
│   ├── sign
│   └── package
├── lib/
│   ├── (macho → orchestrator)         # Mach-O helpers + gate → Elixir Orchestrator.Macho (Phase 2; bash macho.sh removed)
│   └── naming.*                       # SOLE owner of tag/asset/latest name strings
├── mise.toml                          # repo-level: pipeline toolchain (pixi, elixir, plugins)
└── .github/workflows/daily.yml        # cron → decide → dynamic matrix → finalize
```

Adding a version = add one `versions.toml` row + a `versions/<ref>/` dir
(`mise.toml` + `pixi.toml` + `pixi.lock`). **No stage/code change.**

### 5.1 `versions.toml`

```toml
[versions.master]
ref = "master"        # git ref in emacsmirror/emacs
channel = "master"    # used in tag: emacs-master-YYYY-MM-DD

# [versions."emacs-30.2"]   # FUTURE: copy a dir + add a row
# ref = "emacs-30.2"
# channel = "30.2"
```

### 5.2 `targets.toml`

```toml
[targets.macos-arm64]
os = "macos"        # aqua {{.OS}} after darwin→macos replacement
arch = "arm64"      # aqua {{.Arch}}
runner = "macos-14" # arm64 hosted runner
enabled = true

# [targets.linux-arm64]   # FUTURE; enabled=false today
```

## 6. Build dependencies & sourcing model

**Rule (D8): mise registry → aqua → pixi/conda.** Validated reality (via
`mise registry`): the autotools and all *linkable* C libraries are only available
with the right shape from **conda-forge (pixi)**. CLI-shaped registry hits
(`tree-sitter`, `coreutils`) are the wrong artifact (CLI vs. library; uutils vs GNU).

### 6.1 Pipeline toolchain (repo-level `mise.toml`) — registry/aqua, locked in `mise.lock`

```toml
[tools]
pixi   = "0.70.2"   # EXACT pin (Phase 1): deterministic toolchain_hash; no cold-cache lock churn
erlang = "29"
elixir = "1.20.0-otp-29"     # the orchestrator brain
# gh is preinstalled on GitHub runners

[plugins]
# Canonical, local-first path (works identically in CI). See §6.4.
pixi-env  = "https://github.com/esteve/mise-env-pixi"      # activates the per-version pixi PROJECT (pixi.toml + pixi.lock)
vfox-pixi = "https://github.com/esteve/mise-backend-pixi"  # backend: `mise use vfox-pixi:<tool>[@ver]` for conda tools
# (MUST be `vfox-pixi`, NOT `pixi`: installing as `pixi` conflicts with the pixi tool and
#  breaks it — validated Phase 0; see docs/superpowers/validation-log.md.)
```

**Local == CI parity:** GitHub Actions installs this exact `mise.toml` via
`jdx/mise-action` (`mise install`), so a contributor's `mise install` and the CI runner
provision identical, `mise.lock`-pinned tools. Build/test commands live as **mise tasks**
(`mise run test`, `mise run lint`), so local dev, **pregate** (a clean-VM pre-push gate),
and GitHub CI all invoke one identical definition — `mise install && mise run test`
reproduces CI with no version drift. This same `mise.toml`/`mise.lock` is what
`toolchain_hash` fingerprints (§8).

### 6.2 Emacs build/runtime libs (per-version `pixi.toml`) — conda-forge, locked in `pixi.lock`

| Dep | Role | Source | Bundled into `.app`? |
|---|---|---|---|
| autoconf, automake | regenerate `configure` (git checkout) | pixi/conda | no (build-only) |
| pkg-config | `configure` lib discovery | pixi/conda | no (build-only) |
| texinfo (`makeinfo`) | build `.info` docs | pixi/conda | no (build-only) |
| make | build | host Xcode CLT | no |
| gnutls (+ nettle, p11-kit, libtasn1, gmp) | TLS for `url`/package.el | pixi/conda | **yes** |
| libxml2 | XML parsing | pixi/conda | **yes** |
| tree-sitter **library** | `treesit` (`--with-tree-sitter`) | pixi/conda (libtree-sitter + headers) | **yes** — *v1-optional*: drop if conda-forge doesn't ship the lib+headers cleanly on osx-arm64 (Phase 1); re-add later |
| ncurses | terminal (`-nw`) — *not exercised by the GUI* | pixi/conda (texinfo pulls it) | **yes** — bundled generically (GUI-only v1: the dylib only needs to *resolve*; `-nw`/terminfo deferred, §15) |
| **libgccjit** | native-comp | — | **EXCLUDED** in v1 |

> Phase 1 update: `jansson`/`--with-json` removed — Emacs `master` uses a native JSON parser
> (libjansson dropped upstream in Emacs 30). `libxml2` is pinned `<2.14` in `pixi.toml`
> (conda 2.14+ ships runtime-only; 2.13.x bundles `libxml-2.0.pc` + headers). `tree-sitter`
> KEPT (`libtree-sitter` + `tree-sitter.pc` clean on osx-arm64). **ncurses (Phase 2): links from pixi
> (texinfo pulls it) and is bundled generically — GUI-only, so terminfo/`-nw` is deferred (§15).**

### 6.3 The critical boundary: build deps ≠ shipped runtime libs

In CI, pixi installs libs under `.pixi/envs/...`. **On the user's machine that prefix
does not exist.** Therefore `bundle-relocate` must **copy every non-system runtime
dylib (the "bundled" rows + transitive closure) into the `.app` and rewrite install
names**, so the bundle references only system paths (`/usr/lib`, `/System`) and
`@rpath`/`@executable_path`. Build-only deps never enter the bundle.

### 6.4 Pixi integration — mise-first, one way local == CI

**Canonical path = the mise pixi plugins** ("local-first"), and the *same* path runs in
CI (CI is just `mise install` + a mise-activated build), so there is no "works locally,
breaks in CI" gap.

- **Build/bundle libs → a pixi PROJECT** (`pixi.toml` + committed `pixi.lock`)
  activated by **`mise-env-pixi`**. This guarantees the transitive lock (D7) and gives
  one env dir (`.pixi/envs/default/lib`) for `bundle-relocate` to copy from.
- **Ad-hoc / tool-style conda installs → `mise use pixi:<tool>[@<version>]`** via
  **`mise-backend-pixi`** (one-off CLIs, future package-build tooling).
- **Fallback = direct `pixi`** (`pixi install` / `pixi run`) if a plugin misbehaves —
  same `pixi.lock`, so reproducibility is unaffected.

Why the build libs use the *project* rather than per-tool `pixi:<tool>` installs: only
the pixi project commits a `pixi.lock` with the **full transitive closure** (per-tool
`pixi global install` does not give a committed transitive lock). Whether the
`pixi:<tool>` backend transitively locks via `mise.lock` — and the exact backend prefix
(`pixi:` vs `vfox-pixi:`) — are **Phase-0 validations**; until confirmed, the project
path is the reproducible default for the bundled set.

### 6.5 Per-version `versions/master/mise.toml`

```toml
[env]
EMACS_REF = "master"
EMACS_CONFIGURE_FLAGS = "--with-ns --without-native-compilation --with-tree-sitter --with-xml2 --with-gnutls"
_.pixi-env = { tools = true, manifest_path = "./pixi.toml" }   # activate the locked build env (mise-env-pixi)
```

## 7. Orchestration brain (Elixir) & state

**Split (D4):** mise locks inputs; **Elixir owns all decisions as pure functions**;
bash is glue.

### 7.1 Pure core (100% unit-testable, no IO)

| Module | Function | Responsibility |
|---|---|---|
| `Core.Hash` | `inputs_hash/1` | sha256 of a version's locked inputs (raw bytes; lockfiles are never hand-edited) |
| `Core.Detect` | `changed?/2` → `{bool, reason}` | compare current state vs. last-released; reason = `:upstream_sha` \| `:inputs_hash` \| `:first_run` |
| `Core.Tag` | `next_tag/3` | `emacs-<channel>-<date>[.N]`; `.N` from the existing-tag list (injected) |
| `Core.Decide` | `plan/4` → `%Plan{build, skip}` | which refs to build; empty build ⇒ no release |
| `Core.Latest` | `latest_target/2` | which release becomes `latest` |

IO adapters (`Upstream` via `git ls-remote`, `Releases`/`Publisher` via `gh`) sit
behind a behaviour so the core is tested with fixtures only.

### 7.2 Where last-released state lives (the orchestrator's state DB)

A **`build-manifest.json` asset attached to the release marked `latest`** is the
**persistent cross-run state** — *not* committed to the repo (avoids a daily
commit-back loop that races with humans / needs push perms) and needs no external DB.

**It is actively consumed, not decoration:**

1. **Run start — `detect-changes` reads it.** Fetch it from the current `latest`
   release via `gh`; for each version compare its recorded `inputs_hash`/`upstream_sha`
   against the freshly-computed fingerprint (§8). *That comparison is the sole basis
   for "did this version change?"* — without it there is nothing to diff against.
2. **Run end — `finalize` writes it.** After successful builds, write an updated
   manifest (newly released versions get their new tag + fingerprint) and attach it to
   the new `latest` release.
3. **Self-healing fallback.** If `latest` is missing/corrupt, reconstruct last-state by
   scanning recent releases — each release carries the manifest that produced it.

Assets are immutable per release, so reads are free and side-effect-free.

```json
{ "schema": 1,
  "versions": {
    "master": { "ref": "master", "upstream_sha": "…",
                "inputs_hash": "sha256:…", "released_tag": "emacs-master-2026-06-05" } } }
```

## 8. Change-detection / rebuild trigger

A version is **rebuilt** iff its fingerprint differs from the value recorded in the
`latest` release's `build-manifest.json`:

```
toolchain_hash = sha256( bytes(mise.toml) ⧺ bytes(mise.lock) )   # repo-level pipeline toolchain

fingerprint(ref) = sha256(
    toolchain_hash                            # pixi/elixir/etc. pin — change ⇒ rebuild ALL refs
  ⧺ upstream_sha                              # git ls-remote emacsmirror/emacs <ref> (no-dash mirror; resolves identically to emacs-mirror/emacs — Phase 1)
  ⧺ bytes(versions/<ref>/mise.toml)
  ⧺ bytes(versions/<ref>/pixi.toml)
  ⧺ bytes(versions/<ref>/pixi.lock) )
```

`toolchain_hash` folds in the **repo-level** `mise.toml`/`mise.lock`, so a change to
the pipeline toolchain (e.g., a pixi bump) rebuilds every version — honoring the
original "mise.toml/mise.lock change ⇒ rebuild" requirement. `upstream_sha` is also
stored separately so the change `reason` distinguishes an upstream commit from a
dependency bump. First run (no manifest) ⇒ everything builds. Empty `ls-remote` ⇒
skip with a warning (never treated as "changed").

> **Host make/CLT fingerprint gap — RESOLVED Phase 2 (Decision E), wired Phase 5:** host `make`/Xcode
> Command Line Tools are NOT in the fingerprint, so a runner-image CLT/SDK bump silently changes output
> without triggering a rebuild. Resolution: fold `xcode-select -p` + `clang --version` (the CLT/SDK build
> string) into `toolchain_hash`, implemented when the fingerprint is consumed (Phase 5).

## 9. Build, relocation & signing

1. **build-emacs (bash):** under the locked pixi env (`pixi run`); `./autogen.sh`;
   `./configure $EMACS_CONFIGURE_FLAGS LDFLAGS="-Wl,-headerpad_max_install_names
   -Wl,-rpath,$CONDA_PREFIX/lib"`; `make && make install` → `nextstep/Emacs.app` (still linked to
   pixi `@rpath` dylibs). The `-rpath,$CONDA_PREFIX/lib` is required so the in-build dump step
   (`temacs --temacs=pbootstrap`) can load the conda dylibs (Phase-1 finding); relocation deletes it.
2. **relocate (the crux — Elixir `Orchestrator.Relocate`, per D4/§7.1; not bash):** generic over *all*
   Mach-O — BFS the non-system dylib closure into `Emacs.app/Contents/Frameworks/`, set ids to
   `@rpath/<lib>`, rewrite foreign-absolute refs to `@rpath`, add a depth-correct
   `LC_RPATH @loader_path/<rel-to-Frameworks>` to each Mach-O, delete the build-time `$CONDA_PREFIX/lib`
   rpath. **Gate** (`Macho.gate_violations`): **zero** foreign dep paths, **zero** foreign rpaths, every
   `@rpath/<lib>` present in Frameworks — else fail. Clean-room launch = pregate VM with the pixi env
   moved aside (§11.3).
3. **sign (Decision C):** a single **deep** ad-hoc sign of the whole bundle, **last**
   (`codesign --force --deep --sign -`) — per-file signing of the bundle main executable triggers
   bundle-mode codesign that fails on nested helpers (`libexec/rcs2log`). Developer ID + notarization
   deferred (§13/Phase 3).

## 10. Packaging & the aqua contract (verified from the registry branch)

`package` must produce, on the GitHub release:

- **Asset:** `misemacs-<tag>-macos-arm64.tar.gz`
  (registry template `misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.{{.Format}}`,
  `format=tar.gz`, `darwin→macos`, `{{.Version}}` = the git tag).
- **Checksums:** `SHASUMS256.txt` (sha256).
- **Internal layout (contractual):** the tarball unpacks to a top dir named exactly
  like the asset stem, containing:
  ```
  misemacs-<tag>-macos-arm64/Emacs.app/Contents/MacOS/Emacs
  …/Contents/MacOS/bin/emacsclient
  …/Contents/MacOS/bin/etags
  …/Contents/MacOS/bin/ebrowse
  ```
  Note: `emacsclient/etags/ebrowse` must be placed under `Contents/MacOS/bin/` — this
  is **not** Emacs's default install layout; the bundle step moves them there.

**Install invocation:** `mise use aqua:djgoku/misemacs@<tag>` (the dated tag is the
aqua *version*, e.g. `@emacs-master-2026-06-05`). `lib/naming` is the sole owner of
these strings and has a contract test asserting they match the registry template.

## 11. Tag scheme, "latest", and CI

### 11.1 Tags

- Per build: `emacs-<channel>-<YYYY-MM-DD>`; same-day collisions append `.1`, `.2`.
- **`latest`:** the most recent successful release is marked GitHub `latest`
  (`isLatest=true`) and carries the `build-manifest.json`. This is both the human
  "latest" and the orchestrator's state source. (Per-channel `…-latest` aliases =
  future, once >1 channel exists.)

### 11.2 GitHub Actions shape

```
schedule (daily) / workflow_dispatch(force_version) / pull_request(paths: versions/**, *.toml)
        │
   decide (ubuntu, ~1 min)         ← the GATE; emits dynamic matrix + any/release flags
        │  matrix = changed refs × enabled targets   (JSON job output)
        ▼
   build  (macos-14, fail-fast:false, per-cell concurrency)
        │  per cell: pixi install → build → relocate → sign → package → publish own tag
        ▼
   finalize (ubuntu, concurrency: finalize-latest)   ← atomic "latest" + manifest
```

- **Gate:** macOS runners spin up only for changed refs; quiet days cost ~1 Ubuntu
  minute and cut **no** release.
- **Caching:** `ccache` (key `…-<sha>-<hashFiles(pixi.lock)>`, with restore-keys —
  content-addressed, safe); pixi env cache (key on `pixi.lock`); **build-output cache
  exact-key only, no restore-keys** (avoid poisoning).
- **Concurrency/idempotency:** per-cell `concurrency` group serializes same-ref runs;
  `.N` computed against a fresh tag list at publish, retry-on-conflict; `finalize`
  single-writer for `latest`; `action-gh-release` updates idempotently.
- **Partial failure:** `fail-fast:false`; succeeded cells release; a failed cell stays
  "due" for the next run.
- **Dev workflow:** PRs touching `versions/**` build a **dry-run artifact** (no
  release); merge to default branch does **not** auto-release (the daily cron picks up
  the changed lock); `workflow_dispatch(force_version)` forces an immediate build.

### 11.3 Pre-CI gate: pregate (clean-room, macOS + Linux)

[pregate](https://tart.run) clones disposable **macOS + Linux** VMs, pipes the working
tree in (excluding `.git`/build dirs), and runs `.pregate/<os>.sh` — which call the same
shared **mise tasks** used locally and in GitHub CI. A green `pregate` predicts a green CI
run *by construction* (identical tasks), caught **before** pushing:

- **Orchestrator (Phase 0+):** `.pregate/{linux,macos}.sh` run `mise run test` / `lint`.
- **Emacs build (Phase 2+):** `.pregate/macos.sh` runs the relocatable-`.app` build in a
  **clean macOS VM** — the highest-value use: it reproduces the "builds on my polluted Mac,
  fails clean" failure (the relocation/dylib-bundling crux) and validates **before**
  spending expensive GitHub macOS-runner minutes.

## 12. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Ad-hoc `.app` blocked on other Macs (Gatekeeper/quarantine) | **Assumed OK** — existing `djgoku/misemacs` releases already install on other Macs; *optionally* double-validate on a 2nd Mac in Phase 3; Developer ID is the fallback (§13) |
| Mach-O header overflow on relink | `-Wl,-headerpad_max_install_names`; the `Orchestrator.Macho` gate verifies via `otool` and fails loudly |
| Incomplete dylib closure (breaks only on clean machine) | Transitive walk; `otool` gate asserts zero non-system refs; smoke-launch on a clean runner — and locally in a clean macOS VM via **pregate** before CI (§11.3) |
| Naming drift vs. aqua registry | `lib/naming` is sole owner + contract test against the registry template |
| `tree-sitter`/`coreutils` registry traps (CLI vs lib) | Sourced from conda-forge as the *library*; `--with-tree-sitter` is v1-optional/droppable (§6.2) |
| Pixi mise-plugins immaturity | Plugins are the canonical path but **not load-bearing**: direct `pixi` is the documented fallback (same `pixi.lock`) |
| `.N` tag race (cron + manual rerun) | Workflow `concurrency` group + retry-on-conflict at `gh release create` |
| conda transitive drift | `pixi.lock` locks the full closure; lock change ⇒ fingerprint change ⇒ rebuild |

## 13. Validated facts vs. open questions

**Validated** (this session): aqua asset contract + internal layout (read from the
registry branch); mise registry lacks autotools and ships CLI-shaped `tree-sitter`/
`coreutils` (not the libs); `git ls-remote` resolves refs read-only; `mise.lock` is
content-addressable but its **conda backend does not lock transitive deps** (→ pixi);
`mise-env-pixi` activates a `pixi.toml`/`pixi.lock` env and pixi.lock locks the
closure; `macos-14` is arm64; on arm64 binaries must be ≥ad-hoc signed and
`install_name_tool` invalidates signatures (sign last); GHA dynamic matrix via job
outputs, schedule passes no inputs, `action-gh-release` idempotent, `concurrency`
semantics; local toolchain present (mise 2026.6.0, aqua 2.59, gh 2.92, elixir/OTP 28).

**Open** (resolve during implementation):
- Ad-hoc on a *second* arm64 Mac via the aqua path — **assumed OK** (existing
  `djgoku/misemacs` releases install elsewhere); optional confirm in Phase 3.
- conda-forge `tree-sitter` provides `libtree-sitter`+headers — **RESOLVED: KEEP**
  (`libtree-sitter` + headers + `tree-sitter.pc` confirmed clean on osx-arm64, Phase 1).
- jansson / `--with-json` — **RESOLVED: removed upstream on `master`** (native JSON parser
  since Emacs 30; dep + flag dropped).
- `mise-backend-pixi`: does `pixi:<tool>` transitively lock via `mise.lock`, and is the
  prefix `pixi:` (install name) vs `vfox-pixi:`? (Phase 0.)
- Exact `gh release create` exit code on a pre-existing tag (confirm before Phase 4).
- `--with-ns` Info.plist/icon — **RESOLVED (Phase 2):** the ns build emits a self-contained
  `nextstep/Emacs.app` with a valid `Info.plist` (deep-signs cleanly). The final aqua extraction layout
  (the `bin/` move) is Phase 4.
- `-nw` on ncurses — **DEFERRED:** v1 is GUI-only; ncurses is bundled generically (the dylib resolves),
  and working `-nw` is a post-Phase-4 fast-follow (§15).

## 14. Roadmap — shippable, independently-validated increments

Cheap/risky things proven before macOS minutes are spent.

| Phase | Ships | "Done" = validated by |
|---|---|---|
| **0 Skeleton & contracts** (free) | manifest model + `lib/naming`; Elixir `Core.{Hash,Detect,Tag,Decide,Latest}` | unit tests on fixtures: names match aqua template verbatim; "no change ⇒ no release"; `.N` collisions; first-run base case. Also confirm the mise pixi plugins install + the `pixi:<tool>` prefix + whether `pixi:<tool>`/`pixi.lock` lock transitively |
| **1 Reproducible deps** (local) | per-version pixi PROJECT (`pixi.toml`/`pixi.lock`) via `mise-env-pixi`; `configure`-only run | all deps resolve on osx-arm64 (esp. gnutls closure); **decide tree-sitter in/out** (drop if libtree-sitter isn't clean); configure detects ns/json/xml2/gnutls (+tree-sitter if kept), native-comp off; built Emacs runs `-nw` (throwaway build; ncurses links from pixi → bundled in Phase 2, GUI-only, `-nw` deferred §15); direct-`pixi` fallback verified |
| **2 Build + relocation** (crux) | bash `build-emacs` + Elixir `Orchestrator.Relocate`/`mix relocate` + `Macho` gate | self-contained `.app` launches with the pixi env moved aside / on a **clean** pregate VM; gate green |
| **3 Signing** | ad-hoc sign-last | **assumed good** (existing `djgoku/misemacs` releases install on other Macs); *optionally* double-validate on a 2nd Mac; Developer ID only if it fails |
| **4 Package + publish** | `package` to exact aqua layout + `SHASUMS256.txt`; `publish` (tag/`.N`/latest/manifest) | `mise use aqua:djgoku/misemacs@<tag>` installs & runs end-to-end on a clean box |
| **5 Automate** | decide-gate + daily cron + dynamic matrix + PR dry-run + force-build | run twice/day → 2nd skips; forced change → only that ref; partial-failure releases good cells |
| **6 Prove "trivial to add"** | add `emacs-30.x` via data only | builds & releases with **zero stage/code change** |

## 15. Future enhancements (designed-for, not built)

- **native-comp:** re-enable, build with `libgccjit`, AOT-compile `.eln`, bundle
  `libgccjit`. (The relocation step is already generic over Mach-O.)
- **Linux + more arches:** add `targets.toml` rows; Linux relocation via `patchelf` +
  bundled `.so` + wrapper (mirrors the macOS approach).
- **Precompiled packages** (vterm, pdf-tools, tree-sitter grammars): **not built in
  v1, but the seams are reserved now** so adding it is additive, not a redesign —
  (1) `bundle-relocate` already walks *all* Mach-O, so a package's `.so`/`.dylib` is
  re-pathed for free; (2) extra build tools slot into a separate pixi packages manifest
  off the core env; (3) a `build-packages` stage inserts between build and relocate
  (file-coupled stages make this local); (4) package declarations fold into the same
  fingerprint (§8), so adding one triggers a rebuild. **Deliberately deferred to a
  post-v1 design pass:** the *user-facing customization UX* — how packages are declared,
  how their versions are pinned/locked, and one-fat-bundle vs. a separate asset variant.
- **Developer ID + notarization:** add behind CI secrets if Phase 3 shows ad-hoc is
  insufficient; pipeline still builds without secrets for contributors.
- **Per-channel `latest` aliases** once >1 channel exists.
- **Terminal Emacs (`emacs -nw`)** — v1 ships **GUI-only** (`Emacs.app`); the NS GUI never
  initializes terminfo, so `-nw` is deliberately **not gated** in Phase 2 and ncurses is just
  bundled generically (the dylib only needs to *resolve* at load). Adding working `-nw` later is a
  **one-row change to `bundle-relocate`**: rewrite the bundled `@rpath/libncurses.6.dylib` install
  name to the system `/usr/lib/libncurses.5.4.dylib`, so TTY frames read the system terminfo DB
  (`/usr/share/terminfo`) natively — the path every macOS Emacs uses. (A *bundled* conda ncurses
  can't, without extra machinery: its compiled-in terminfo search is **only**
  `$CONDA_PREFIX/share/terminfo`, gone on user machines — validated 2026-06-09 via `infocmp -D`;
  the alternative is shipping a terminfo DB + a `TERMINFO_DIRS` launcher.) **When:** a fast-follow
  once the v1 GUI pipeline installs & runs end-to-end (**post-Phase 4**), validated by adding a
  `-nw` smoke to the clean-VM test. Low-risk and additive — no redesign.
- **conda libxml2 `.pc`/headers — revisit the Phase-1 `libxml2 <2.14` pin (TODO).** Phase 1
  pins `libxml2 <2.14` (resolves 2.13.x) because conda-forge libxml2 **2.14+ ships
  runtime-only** (`libxml2.16.dylib` with no `libxml-2.0.pc` or headers), which would force
  Emacs's pkg-config check onto the *system* libxml2 instead of the pixi one. Investigate how
  to use a **newer** conda libxml2 and still obtain its dev files (a separate dev output/
  package, a feedstock build variant, or building the feedstock locally) so the pin can be
  lifted. Ref: libxml2-feedstock `build-locally.py` —
  https://github.com/conda-forge/libxml2-feedstock/blob/main/build-locally.py
```
