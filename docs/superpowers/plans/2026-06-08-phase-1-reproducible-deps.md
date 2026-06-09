# Phase 1 — Reproducible Build Dependencies & Configure Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the reproducible per-version build-dependency set for Emacs `master` (a committed pixi project locking the full conda-forge closure) and prove, against that env only, that `./configure` detects `ns` / `tree-sitter` / `xml2` / `gnutls` with native-comp **off** and that a built `emacs -nw` runs on **system** ncurses — without building the productionized/relocatable pipeline (that is Phase 2).

**Architecture:** A per-version pixi **project** (`versions/master/pixi.toml` + committed `pixi.lock`, D7) supplies the C build/runtime libs; the repo `mise.toml` pins the pixi *tool* and registers the `pixi-env`/`vfox-pixi` plugins; `versions/master/mise.toml` carries `EMACS_REF` + `EMACS_CONFIGURE_FLAGS` + the `_.pixi-env` activation. A single committed validation harness (`scripts/configure-check.sh`) fetches Emacs into a git-ignored work dir and runs `./configure` against the pixi env via **direct `pixi run`** (proving the plugin isn't load-bearing), asserting feature detection from `src/config.h`; an opt-in `--build-smoke` does a throwaway `make` + `-nw` + `otool` to confirm ncurses resolves to system `/usr/lib`. A small Elixir test pins the "add-a-version = data" layout invariant.

**Tech Stack:** mise 2026.6.1 (toolchain + task seam), pixi 0.70.2 (conda-forge project + lock), bash (validation harness), Elixir 1.20.0-otp-29 / ExUnit (layout-contract test), `emacsmirror/emacs` `master` (build target). Spec: `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` (§6 build-deps, §8 fingerprint, §14 Phase 1 row).

**This is the Phase 1 plan only.** Phases 2–6 each get their own plan. Work happens on `phase-1-reproducible-deps` off `main`; merge back when Phase 1 lands and CI is green.

---

## Validated facts this plan is built on (Phase 1 spike, 2026-06-08)

All probes were read-only or in throwaway temp dirs (`git ls-remote`, raw `configure.ac` fetch, ephemeral `pixi` solves). Re-confirmed empirically during execution by Task 6.

| # | Fact | Evidence |
|---|------|----------|
| V1 | `emacsmirror/emacs` (no dash) **and** `emacs-mirror/emacs` (dash) both resolve `master` to the **same** SHA. This plan uses the **no-dash** form per user. | `git ls-remote --heads <both> master` → identical SHA `a0dc061…` |
| V2 | **Emacs `master` removed libjansson** — zero `json`/`jansson`/`HAVE_JSON`/`--with-json` references in `configure.ac`. JSON is native since Emacs 30. → **drop `jansson` dep + `--with-json` flag.** | `curl raw configure.ac \| grep -i json` → empty |
| V3 | Valid flags on master: `--with-ns`, `--without-native-compilation`, `--with-tree-sitter`, `--with-xml2`, `--with-gnutls`. | `configure.ac` AC_ARG_WITH/option blocks present for each |
| V4 | `gnutls`, `tree-sitter`, **and** `libxml2` are all detected via **pkg-config** (`EMACS_CHECK_MODULES`): `tree-sitter >= 0.20.2`, `libxml-2.0 > 2.6.17`, gnutls. | `configure.ac` lines ~3985, ~4017–4057, ~5784–5822 |
| V5 | conda-forge `libtree-sitter` (0.26.9) ships `tree-sitter.pc` + `include/tree_sitter/api.h`; `gnutls` ships `gnutls.pc`. | temp `pixi add` + `ls .pixi/envs/default/lib/pkgconfig` |
| V6 | conda `libxml2` **2.14+ ships runtime-only** (`libxml2.16.dylib`, no headers/`.pc`). Pinning **`libxml2 <2.14` → 2.13.9** restores `libxml-2.0.pc` + `include/libxml2/libxml/*.h`. | temp `pixi add libxml2` (2.15: no pkgconfig dir) vs `pixi add "libxml2<2.14"` (2.13.9: `libxml-2.0.pc` present) |
| V7 | Full set `autoconf automake pkg-config texinfo gnutls "libxml2<2.14" libtree-sitter` co-resolves on osx-arm64; gnutls closure = `nettle gmp p11-kit libtasn1 libidn2 libunistring`. `ncurses-6.6` is pulled transitively (texinfo→perl). | temp `pixi add --no-install` + lock grep |
| V8 | Because `ncurses` is in the env, a global `-L$PREFIX/lib` would make Emacs link **pixi** ncurses. Using **pkg-config per-lib discovery (no global `-L`/`-I`)** keeps gnutls/xml2/tree-sitter from pixi while ncurses falls through to system `/usr/lib`. | V4–V7 + each `.pc`'s own `Libs: -L${libdir}` |
| V9 | mise 2026.6.1; pixi 0.70.2 in `mise ls`; `vfox-pixi` plugin installed globally; **`pixi-env` (mise-env-pixi) is NOT installed** → Task 1 must install it. | `mise plugin ls` |
| V10 | Emacs config.h ground-truth macros: `HAVE_GNUTLS`, `HAVE_LIBXML2`, `HAVE_TREE_SITTER`, `HAVE_NS` (set); `HAVE_NATIVE_COMP` (absent when off). Summary lines: `What window system should Emacs use?  nextstep`; `Does Emacs have native lisp compiler?  no`. | `configure.ac` AC_DEFINE + summary block (lines ~7600, ~7677–7694) |

## Decisions frozen here (deviations from the committed spec, reconciled in Task 7)

1. **pixi tool pinned EXACT** `0.70.2` (spec §6.1 said `latest`) — avoids `mise.lock` re-resolution churn on cold caches and makes "toolchain change ⇒ rebuild all refs" intentional.
2. **`jansson` dropped, `--with-json` dropped** (V2) — removed upstream on master.
3. **`libxml2` pinned `<2.14`** (V6) — newer conda libxml2 is runtime-only; the pin restores dev files so Emacs uses the **pixi** libxml2, not system.
4. **Configure uses pkg-config-scoped discovery, no global `-L`/`-I`** (V8) — ncurses stays system (`/usr/lib`), per spec §6.2.
5. **Upstream repo = `emacsmirror/emacs`** (no dash) (V1) — spec §8 used the dash form; both are identical mirrors.
6. **`--with-tree-sitter` KEPT** (validation-log §4 + V5) — `libtree-sitter` + headers + `.pc` are clean on osx-arm64.

---

## File Structure

- `mise.toml` (repo root) — MODIFY: add `pixi = "0.70.2"` to `[tools]`; add `[plugins]`; add `[tasks.configure-check]`.
- `mise.lock` (repo root) — MODIFY: regenerated with pixi pinned.
- `.gitignore` (repo root) — CREATE: ignore `.work/` (ephemeral Emacs checkouts).
- `versions/master/pixi.toml` — CREATE (generated by `pixi init` + `pixi add`): the conda-forge build/runtime deps.
- `versions/master/pixi.lock` — CREATE (generated): full transitive closure (committed; D7).
- `versions/master/.gitignore` — CREATE (pixi-generated): ignore `.pixi/` (the installed env).
- `versions/master/mise.toml` — CREATE: `EMACS_REF`, `EMACS_CONFIGURE_FLAGS`, `_.pixi-env` wiring.
- `scripts/configure-check.sh` — CREATE: the Phase-1 validation harness (configure-only by default; `--build-smoke` adds make + `-nw` + `otool`).
- `orchestrator/lib/orchestrator/manifest.ex` — MODIFY: add `version_input_files/1` + `missing_version_files/2`.
- `orchestrator/test/orchestrator/version_layout_test.exs` — CREATE: pin the "add-a-version = data" on-disk invariant.
- `docs/superpowers/validation-log.md` — MODIFY: append the Phase 1 findings section (real results).
- `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` — MODIFY: reconcile §6.1/§6.2/§6.5/§8/§13.

---

## Branch setup (do once, before Task 1)

We are already in an isolated git worktree (`.claude/worktrees/condescending-kilby-3c6964`). `main` is checked out in the primary repo, so create the Phase-1 branch **from** `main`'s commit directly in this worktree (do **not** `git checkout main` — it is checked out elsewhere).

- [ ] **Create the Phase-1 branch off `main`:**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
git status --short            # expect clean
git checkout -b phase-1-reproducible-deps main
git branch --show-current     # expect: phase-1-reproducible-deps
git log --oneline -1 main     # expect: bb6be08 (Phase 0 tip)
```

---

## Task 1: Repo `mise.toml` — pin pixi + register/install the pixi plugins

**Files:**
- Modify: `mise.toml` (repo root)
- Modify (generated): `mise.lock`

- [ ] **Step 1: Add the pixi tool pin + the `[plugins]` table**

Edit `mise.toml` so `[tools]` includes pixi and a `[plugins]` table is added. The full `[tools]` block becomes:

```toml
[tools]
erlang = "29"
elixir = "1.20.0-otp-29"
pixi   = "0.70.2"   # EXACT pin (not "latest"): deterministic toolchain_hash; no cold-cache lock churn

[plugins]
# Canonical local-first pixi path (identical in CI). NOT load-bearing: direct `pixi`/`pixi run`
# is the documented fallback (same pixi.lock). See spec §6.1/§6.4.
pixi-env  = "https://github.com/esteve/mise-env-pixi"      # activates a per-version pixi PROJECT (the `_.pixi-env` env directive)
vfox-pixi = "https://github.com/esteve/mise-backend-pixi"  # backend: `mise use vfox-pixi:<tool>` for ad-hoc conda tools (MUST be vfox-pixi, NOT pixi — validation-log §1)
```

Leave the existing `[tasks.test]` / `[tasks.lint]` / `[tasks.fmt]` blocks untouched.

- [ ] **Step 2: Install the `pixi-env` plugin (V9: not yet installed) and confirm `vfox-pixi`**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
mise plugin install pixi-env https://github.com/esteve/mise-env-pixi
mise plugin ls    # expect both pixi-env and vfox-pixi present
```

Expected: `pixi-env` and `vfox-pixi` both listed. (`vfox-pixi` was already global per V9; re-running its install is harmless.)

- [ ] **Step 3: Trust, install, and lock**

```bash
mise trust
mise install        # provisions pixi 0.70.2 (cached globally already)
mise lock
```

- [ ] **Step 4: Verify the pixi tool resolves to 0.70.2 and the lock recorded it**

```bash
mise exec -- pixi --version        # expect: pixi 0.70.2
git diff --stat mise.lock          # expect mise.lock changed (pixi entry added)
grep -i pixi mise.lock | head      # expect a pixi 0.70.2 record
```

Expected: `pixi 0.70.2`; `mise.lock` carries a pixi entry. (Exact pin ⇒ no future re-resolution drift.)

- [ ] **Step 5: Commit**

```bash
git add mise.toml mise.lock
git commit -m "chore(deps): pin pixi 0.70.2 + register pixi-env/vfox-pixi plugins"
```

---

## Task 2: `versions/master/` pixi project (`pixi.toml` + `pixi.lock`)

The reproducible build/runtime libs (D7). **Generate** the manifest + lock via pixi (never hand-author the lock); commit both plus pixi's `.gitignore`.

**Files:**
- Create (generated): `versions/master/pixi.toml`
- Create (generated): `versions/master/pixi.lock`
- Create (pixi-generated): `versions/master/.gitignore`

- [ ] **Step 1: Initialize the pixi project pinned to osx-arm64**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
mkdir -p versions/master
( cd versions/master && mise exec -- pixi init --platform osx-arm64 . )
```

Expected: creates `versions/master/pixi.toml` (with `platforms = ["osx-arm64"]`) and a `.gitignore` containing `.pixi`.

- [ ] **Step 2: Add the conda-forge build/runtime deps (V2/V6 corrected set — no jansson; libxml2 pinned)**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964/versions/master
mise exec -- pixi add autoconf automake pkg-config texinfo gnutls "libxml2<2.14" libtree-sitter
mise exec -- pixi install
```

Expected: all 7 deps added; `pixi install` solves + writes `pixi.lock` + creates `.pixi/envs/default/`. `libxml2` resolves to **2.13.x** (the `<2.14` pin, V6).

- [ ] **Step 3: Annotate the libxml2 pin in `pixi.toml` (capture the rationale at the source)**

After generation, add a comment above the `libxml2` line in `versions/master/pixi.toml` (exact surrounding text is pixi-generated; match the actual line):

```toml
# Pinned <2.14: conda libxml2 2.14+ ships runtime-only (no headers/.pc); 2.13.x bundles
# libxml-2.0.pc + headers so Emacs's pkg-config check uses THIS libxml2, not system. (Phase 1, V6)
libxml2 = "<2.14"
```

- [ ] **Step 4: Verify the lock holds the full transitive closure + the dev files exist**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964/versions/master
echo "== gnutls closure (expect all four) =="
grep -oiE '(nettle|gmp|p11-kit|libtasn1)-[0-9][^/ ]*' pixi.lock | sort -u
echo "== tree-sitter + libxml2 2.13 in lock =="
grep -oiE 'libtree-sitter-[0-9.]+' pixi.lock | sort -u
grep -oiE 'libxml2-2\.13\.[0-9]+' pixi.lock | sort -u
echo "== .pc files present in the env =="
ls .pixi/envs/default/lib/pkgconfig/ | grep -E 'gnutls\.pc|libxml-2\.0\.pc|tree-sitter\.pc'
echo "== pkg-config (from pixi) resolves all three against the env =="
.pixi/envs/default/bin/pkg-config --modversion gnutls libxml-2.0 tree-sitter
```

Expected: `nettle gmp p11-kit libtasn1` all present; `libtree-sitter-0.26.x`; `libxml2-2.13.x`; the three `.pc` files listed; three version numbers printed (e.g. `3.8.13`, `2.13.9`, `0.26.9`).

- [ ] **Step 5: Confirm `.pixi/` is git-ignored, then commit only the manifest + lock + `.gitignore`**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
cat versions/master/.gitignore                       # expect a line: .pixi  (add it if pixi didn't)
git status --porcelain versions/master/.pixi          # expect EMPTY (ignored)
git add versions/master/pixi.toml versions/master/pixi.lock versions/master/.gitignore
# include versions/master/.gitattributes too if pixi init created one:
[ -f versions/master/.gitattributes ] && git add versions/master/.gitattributes || true
git commit -m "feat(deps): master pixi project — conda-forge build libs (gnutls/xml2/tree-sitter, libxml2<2.14)"
```

If `versions/master/.gitignore` does **not** contain `.pixi`, add it before committing:

```bash
printf '.pixi\n' >> versions/master/.gitignore
```

---

## Task 3: `versions/master/mise.toml` — env + pixi-env activation

**Files:**
- Create: `versions/master/mise.toml`

- [ ] **Step 1: Write the per-version env file (V2/V3 corrected flags — no `--with-json`)**

Create `versions/master/mise.toml`:

```toml
# Per-version build env for emacs-master. Adding a version = copy this dir + a versions.toml row.
[env]
EMACS_REF = "master"   # git ref in emacsmirror/emacs (no-dash mirror; identical to emacs-mirror)

# native-comp OFF (v1, no libgccjit); JSON is native on master (jansson removed upstream);
# ncurses intentionally NOT requested → Emacs links system /usr/lib (spec §6.2).
EMACS_CONFIGURE_FLAGS = "--with-ns --without-native-compilation --with-tree-sitter --with-xml2 --with-gnutls"

# Activate the locked pixi build env (mise-env-pixi plugin): puts pkg-config / autoconf /
# automake / makeinfo on PATH and exposes the gnutls/libxml2/tree-sitter libs+headers.
_.pixi-env = { tools = true, manifest_path = "./pixi.toml" }
```

- [ ] **Step 2: Trust the dir and verify the env vars resolve**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964/versions/master
mise trust
mise exec -- sh -c 'echo "REF=$EMACS_REF"; echo "FLAGS=$EMACS_CONFIGURE_FLAGS"'
```

Expected: `REF=master` and the corrected `FLAGS=…` (no `--with-json`).

- [ ] **Step 3: Verify mise-env-pixi activation exposes the pixi toolchain (the plugin path works)**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964/versions/master
mise exec -- sh -c 'command -v pkg-config; pkg-config --modversion gnutls libxml-2.0 tree-sitter'
```

Expected: `pkg-config` resolves **inside** `versions/master/.pixi/envs/default/bin/`, and three versions print. If it does not activate, confirm `pixi-env` is installed (Task 1 Step 2) and the directive name matches the plugin README (`_.pixi-env`).

- [ ] **Step 4: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
git add versions/master/mise.toml
git commit -m "feat(deps): master per-version env (EMACS_REF/flags + pixi-env activation)"
```

---

## Task 4: Version-dir layout contract (Elixir, TDD) — "add a version = data"

Now that the first real `versions/master/` dir exists, pin the invariant that every `versions.toml` entry has its three build-input files on disk. Runs in the existing Ubuntu `orchestrator-ci` (files are committed, so it is platform-independent).

**Files:**
- Modify: `orchestrator/lib/orchestrator/manifest.ex`
- Create: `orchestrator/test/orchestrator/version_layout_test.exs`

- [ ] **Step 1: Write the failing test**

Create `orchestrator/test/orchestrator/version_layout_test.exs`:

```elixir
defmodule Orchestrator.VersionLayoutTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Manifest

  @repo_root Path.expand("../../..", __DIR__)

  test "version_input_files/1 lists the three per-version build inputs (relative to repo root)" do
    assert Manifest.version_input_files("master") == [
             "versions/master/mise.toml",
             "versions/master/pixi.toml",
             "versions/master/pixi.lock"
           ]
  end

  test "every versions.toml entry has its versions/<name>/ build inputs committed on disk" do
    {:ok, vbin} = File.read(Path.join(@repo_root, "versions.toml"))
    {:ok, vmap} = Toml.decode(vbin)
    names = Map.keys(Map.get(vmap, "versions", %{}))

    assert names != [], "versions.toml has no [versions.*] entries"
    assert Manifest.missing_version_files(@repo_root, names) == []
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964/orchestrator
mise exec -- mix test test/orchestrator/version_layout_test.exs
```

Expected: FAIL (`Manifest.version_input_files/1` undefined).

- [ ] **Step 3: Implement the helpers in `Orchestrator.Manifest`**

Add these two functions to `orchestrator/lib/orchestrator/manifest.ex` (inside the module, after `load/2`):

```elixir
  @version_input_files ~w(mise.toml pixi.toml pixi.lock)

  @doc """
  The per-version build-input files (relative to repo root) that MUST exist for a version.
  These are exactly the bytes folded into the §8 fingerprint (`mise_toml`, `pixi_toml`,
  `pixi_lock`). "Add a version = data": a new `versions.toml` row needs a `versions/<name>/`
  dir holding these three files — no code change.
  """
  @spec version_input_files(String.t()) :: [String.t()]
  def version_input_files(name) do
    Enum.map(@version_input_files, &Path.join(["versions", name, &1]))
  end

  @doc """
  Returns the version-input files MISSING under `repo_root` for the given version names
  (empty list = all present). Fail-loud helper for the layout-contract test / future CLI.
  """
  @spec missing_version_files(Path.t(), [String.t()]) :: [String.t()]
  def missing_version_files(repo_root, names) do
    for name <- names,
        rel <- version_input_files(name),
        not File.exists?(Path.join(repo_root, rel)),
        do: rel
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
mise exec -- mix test test/orchestrator/version_layout_test.exs
```

Expected: PASS (2 tests, 0 failures).

- [ ] **Step 5: Run the full suite + lint (the same tasks pregate/CI run)**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
mise run test
mise run lint
```

Expected: both PASS — all modules green, no warnings, formatting clean.

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/manifest.ex orchestrator/test/orchestrator/version_layout_test.exs
git commit -m "feat(manifest): version-dir layout contract (add-a-version = data)"
```

---

## Task 5: `scripts/configure-check.sh` — the Phase-1 validation harness

Committed, repeatable, parameterized by version (default `master`). Configure-only by default; `--build-smoke` adds the throwaway `make` + `-nw` + `otool`. This is a **validation harness**, not the Phase-2 `build-emacs` pipeline stage (no relocation/bundling/signing/CI).

**Files:**
- Create: `scripts/configure-check.sh`
- Modify: `mise.toml` (add `[tasks.configure-check]`)
- Create: `.gitignore` (repo root) — ignore `.work/`

- [ ] **Step 1: Write the harness**

Create `scripts/configure-check.sh`:

```bash
#!/usr/bin/env bash
# Phase 1 validation: prove the per-version pixi env resolves Emacs's build deps and that
# ./configure detects NS / tree-sitter / xml2 / gnutls (native-comp OFF) on osx-arm64.
#
# Strategy (V8): pkg-config-SCOPED discovery — set PKG_CONFIG/PKG_CONFIG_PATH and prepend the
# pixi env bin to PATH, but DO NOT export a global -L/-I. pkg-config emits each lib's own
# -L/-I (gnutls/libxml2/tree-sitter come from pixi), while ncurses falls through to the
# system /usr/lib (spec §6.2: ncurses = system, not bundled).
#
# Configure-only by default. `--build-smoke` additionally runs a THROWAWAY `make` +
# `emacs -nw` + `otool -L` to confirm ncurses links system /usr/lib. NOT the Phase-2
# relocatable build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-master}"
SMOKE="${2:-}"
VDIR="$REPO_ROOT/versions/$VERSION"
WORK="$REPO_ROOT/.work/emacs-$VERSION"
PIXI=(mise exec -- pixi)   # pixi pinned in repo mise.toml

[ -f "$VDIR/pixi.toml" ] || { echo "FATAL: $VDIR/pixi.toml missing — run Task 2 first"; exit 1; }

# Read this version's build inputs from its mise env (single source of truth).
EMACS_REF="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_REF:?EMACS_REF unset}"')"
EMACS_FLAGS="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_CONFIGURE_FLAGS:?EMACS_CONFIGURE_FLAGS unset}"')"
echo ">> version=$VERSION ref=$EMACS_REF"
echo ">> flags=$EMACS_FLAGS"

echo ">> [0a] mise-env-pixi activation exposes the pixi toolchain"
( cd "$VDIR" && mise exec -- sh -c 'command -v pkg-config && pkg-config --modversion gnutls libxml-2.0 tree-sitter' )

echo ">> [0b] direct pixi fallback (NO mise-env-pixi) exposes the same toolchain"
"${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" sh -c 'command -v pkg-config && pkg-config --modversion gnutls libxml-2.0 tree-sitter'

echo ">> [1] fetch emacsmirror/emacs $EMACS_REF (shallow) -> $WORK"
mkdir -p "$REPO_ROOT/.work"
if [ -d "$WORK/.git" ]; then
  git -C "$WORK" fetch --depth 1 origin "$EMACS_REF"
  git -C "$WORK" checkout -q -f FETCH_HEAD
else
  rm -rf "$WORK"
  git clone --depth 1 --branch "$EMACS_REF" https://github.com/emacsmirror/emacs "$WORK"
fi

echo ">> [2] autogen + configure UNDER the pixi env (direct pixi run = the validated fallback path)"
"${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" bash -euo pipefail -c '
  cd "'"$WORK"'"
  export PATH="$CONDA_PREFIX/bin:$PATH"
  export PKG_CONFIG="$CONDA_PREFIX/bin/pkg-config"
  export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig"
  # Deliberately NO global -L$CONDA_PREFIX/lib / -I$CONDA_PREFIX/include (V8).
  ./autogen.sh
  ./configure '"$EMACS_FLAGS"' LDFLAGS=-Wl,-headerpad_max_install_names 2>&1 | tee "'"$WORK"'/configure.log"
'

echo ">> [3] assert feature detection (src/config.h ground truth + configure summary)"
cfg="$WORK/src/config.h"; log="$WORK/configure.log"; fail=0
need() { grep -qE "^#define $1 1\b" "$cfg" && echo "  OK   define $1" || { echo "  MISS define $1"; fail=1; }; }
none() { grep -qE "^#define $1\b" "$cfg" && { echo "  BAD  define $1 present"; fail=1; } || echo "  OK   absent $1"; }
need HAVE_GNUTLS
need HAVE_LIBXML2
need HAVE_TREE_SITTER
need HAVE_NS
none HAVE_NATIVE_COMP
grep -qE 'window system should Emacs use\?[[:space:]]+nextstep' "$log" || { echo "  MISS summary: window_system=nextstep"; fail=1; }
grep -qE 'native lisp compiler\?[[:space:]]+no'                "$log" || { echo "  MISS summary: native-comp=no";        fail=1; }
[ "$fail" = 0 ] || { echo ">> FAIL: feature detection"; exit 1; }
echo ">> ALL FEATURES DETECTED (ns, tree-sitter, xml2, gnutls; native-comp OFF)"

if [ "$SMOKE" = "--build-smoke" ]; then
  echo ">> [4] THROWAWAY make + -nw smoke + otool provenance (NOT the Phase-2 build)"
  "${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" bash -euo pipefail -c '
    cd "'"$WORK"'"; export PATH="$CONDA_PREFIX/bin:$PATH"
    make -j"$(sysctl -n hw.ncpu)"
  '
  bin="$WORK/src/emacs"
  echo ">> [4a] batch run (dyld must resolve every linked dylib)"
  "$bin" --batch --eval '(princ (format "ok emacs %s\n" emacs-version))'
  echo ">> [4b] real -nw launch in a pty (initializes terminfo/ncurses)"
  TERM=xterm-256color script -q /dev/null "$bin" -nw -Q --eval '(kill-emacs 0)' >/dev/null && echo "  -nw OK"
  echo ">> [4c] otool -L provenance (ncurses MUST be /usr/lib; gnutls/xml2/tree-sitter from pixi)"
  otool -L "$bin" | grep -iE 'ncurses|gnutls|xml2|tree-sitter|nettle|p11-kit|tasn1|gmp|idn2|unistring' || true
  echo ">> [4d] GATE: ncurses resolves to system /usr/lib"
  if otool -L "$bin" | grep -i ncurses | grep -q '/usr/lib/'; then
    echo "  OK   ncurses = /usr/lib (system)"
  else
    echo "  WARN ncurses NOT system — record for Phase 2"; fail=1
  fi
  [ "$fail" = 0 ] || { echo ">> FAIL: -nw/ncurses gate"; exit 1; }
fi
echo ">> configure-check: PASS"
```

```bash
chmod +x /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964/scripts/configure-check.sh
```

> Note: `script -q /dev/null <cmd …>` is the BSD/macOS form (runs the trailing command in a pty). If a runner's `script` rejects it, the executor may substitute `expect`/`util-linux script`; the otool gate ([4c]/[4d]) and the batch run ([4a]) remain the load-bearing checks.

- [ ] **Step 2: Add the `configure-check` mise task + ignore the work dir**

Add to repo `mise.toml` (after the existing `[tasks.fmt]` block):

```toml
[tasks.configure-check]
description = "Phase 1: fetch Emacs + ./configure against the per-version pixi env; assert feature detection (configure-only)"
run = "bash scripts/configure-check.sh master"
```

Create repo-root `.gitignore` (it does not exist yet):

```gitignore
# Ephemeral Emacs source checkouts used by scripts/configure-check.sh (Phase 1 validation)
/.work/
```

- [ ] **Step 3: Smoke-validate the script parses (no execution yet)**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
bash -n scripts/configure-check.sh && echo "syntax OK"
python3 -c "import tomllib,sys; tomllib.load(open('mise.toml','rb')); print('mise.toml OK')"
```

Expected: `syntax OK` and `mise.toml OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/configure-check.sh mise.toml .gitignore
git commit -m "feat(validation): configure-check harness (pkg-config-scoped configure + -nw smoke)"
```

---

## Task 6: Run the validation (the Phase-1 "done" proof) + record findings

This is the empirical heart of Phase 1. **It runs a full Emacs `make` — expect several minutes.** Capture real output; the assertions make pass/fail explicit.

**Files:**
- Modify: `docs/superpowers/validation-log.md`

- [ ] **Step 1: Run configure-only first (fast — proves deps + detection + both activation paths)**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
bash scripts/configure-check.sh master 2>&1 | tee /tmp/phase1-configure.log
```

Expected: `[0a]`/`[0b]` both print three versions; `[3]` prints `OK` for `HAVE_GNUTLS`/`HAVE_LIBXML2`/`HAVE_TREE_SITTER`/`HAVE_NS`, `absent HAVE_NATIVE_COMP`; ends `ALL FEATURES DETECTED`.

**Troubleshooting (empirical discovery is expected here):**
- `autogen.sh` fails for a missing tool (e.g. `autopoint`/`gettext`) → add it to `versions/master/pixi.toml` (`pixi add <tool>`), re-run Task 2 Step 4–5, re-run.
- A lib reports `no` → check `grep -i <lib> "$WORK/configure.log"`; usually a missing `.pc` (confirm `pkg-config --modversion <m>` under `pixi run`) or PKG_CONFIG_PATH not reaching the env.

- [ ] **Step 2: Run the full proof with the throwaway build + `-nw` + otool**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
bash scripts/configure-check.sh master --build-smoke 2>&1 | tee /tmp/phase1-smoke.log
```

Expected: `[4a]` prints `ok emacs <version>`; `[4b]` prints `-nw OK`; `[4c]` lists dylibs; `[4d]` prints `OK ncurses = /usr/lib (system)`; ends `configure-check: PASS`.

- [ ] **Step 3: Capture the key evidence for the log**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
echo "== upstream SHA =="; git ls-remote --heads https://github.com/emacsmirror/emacs master
echo "== configure summary (features) =="; grep -E 'window system should Emacs use|native lisp compiler|-lgnutls|-lxml2|-ltree-sitter' .work/emacs-master/configure.log
echo "== otool ncurses/gnutls/xml2/tree-sitter provenance =="; otool -L .work/emacs-master/src/emacs | grep -iE 'ncurses|gnutls|xml2|tree-sitter'
```

- [ ] **Step 4: Append the Phase 1 section to `docs/superpowers/validation-log.md`**

Append (fill in the **real** values from Steps 1–3 — replace every `…`):

```markdown

## 2026-06-08 — Phase 1: reproducible deps + configure-only validation

Environment: macOS arm64, mise 2026.6.1, pixi 0.70.2 (repo-pinned). Build target:
`emacsmirror/emacs` master (no-dash mirror; identical SHA to `emacs-mirror/emacs`).

### 1. Dep set & lock (D7) — CONFIRMED
- `versions/master/pixi.toml`: autoconf, automake, pkg-config, texinfo, gnutls, `libxml2<2.14`, libtree-sitter. **No jansson** (removed on master — native JSON).
- `pixi.lock` transitive closure includes gnutls's nettle/gmp/p11-kit/libtasn1 (+ libidn2/libunistring); libtree-sitter …; libxml2 2.13.… → D7 holds.
- **libxml2 pinned `<2.14`:** conda 2.14+ ships runtime-only (no `.pc`/headers); 2.13.x bundles `libxml-2.0.pc` + headers → Emacs uses the **pixi** libxml2.

### 2. `--with-json`/jansson REMOVED on master — CONFIRMED
- `configure.ac` has zero JSON references; flags = `--with-ns --without-native-compilation --with-tree-sitter --with-xml2 --with-gnutls`.

### 3. configure detection (against the pixi env) — RESULT
- src/config.h: HAVE_GNUTLS=…, HAVE_LIBXML2=…, HAVE_TREE_SITTER=…, HAVE_NS=…, HAVE_NATIVE_COMP absent=….
- summary: `What window system should Emacs use? …` / `Does Emacs have native lisp compiler? …`.

### 4. Activation paths — RESULT
- mise-env-pixi (`_.pixi-env`) activates the env: pkg-config at `versions/master/.pixi/envs/default/bin` … 
- **direct `pixi run` (no plugin)** resolves gnutls/libxml-2.0/tree-sitter and runs configure: … → plugin is NOT load-bearing (fallback confirmed).

### 5. `-nw` on system ncurses — RESULT
- throwaway `make` … ; `emacs -nw -Q --eval '(kill-emacs 0)'` … ; `otool -L src/emacs`:
  ncurses → `/usr/lib/…` (system ✓); gnutls/xml2/tree-sitter → pixi env (pre-relocation, expected).

### Decisions for Phase 2
- ncurses = system `/usr/lib` (do NOT bundle). gnutls/libxml2/tree-sitter (+ gnutls closure) = bundle from the pixi env.
- Un-fingerprinted host `make`/CLT gap (spec §8) still open — decide in Phase 2 (source `make` from pixi, or fold CLT/SDK into toolchain_hash).
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/validation-log.md
git commit -m "docs: record Phase 1 reproducible-deps + configure validation findings"
```

---

## Task 7: Spec reconciliation (the validated deviations)

Update the committed design spec so it matches Phase-1 reality. (Spec/plan docs are committable in this repo as of 2026-06-08.)

**Files:**
- Modify: `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`

- [ ] **Step 1: §6.1 — pin pixi exact**

Change the `[tools]` example line:

```toml
pixi   = "latest"   # mise registry; backs the pixi plugins below
```
→
```toml
pixi   = "0.70.2"   # EXACT pin (Phase 1): deterministic toolchain_hash; no cold-cache lock churn
```

- [ ] **Step 2: §6.2 — drop jansson; annotate libxml2 + native JSON**

In the build-libs table, **remove the `jansson` row** and add a note under the table:

```markdown
> Phase 1 update: `jansson`/`--with-json` removed — Emacs `master` uses a native JSON parser
> (libjansson dropped upstream in Emacs 30). `libxml2` is pinned `<2.14` in `pixi.toml`
> (conda 2.14+ ships runtime-only; 2.13.x bundles `libxml-2.0.pc` + headers). `tree-sitter`
> KEPT (`libtree-sitter` + `tree-sitter.pc` clean on osx-arm64). ncurses stays **system**.
```

- [ ] **Step 3: §6.5 — corrected flags (drop `--with-json`)**

```toml
EMACS_CONFIGURE_FLAGS = "--with-ns --without-native-compilation --with-tree-sitter --with-xml2 --with-gnutls"
```

Remove the now-stale `--with-json` note lines under that block (the tree-sitter v1-optional note also resolves to KEPT).

- [ ] **Step 4: §8 — upstream repo name**

Change `git ls-remote emacs-mirror/emacs <ref>` → `git ls-remote emacsmirror/emacs <ref>` and add: `(no-dash mirror; resolves identically to emacs-mirror/emacs — Phase 1 V1)`.

- [ ] **Step 5: §13 — move the resolved open questions**

Update the two relevant "Open" bullets: tree-sitter lib+headers → **resolved KEEP** (Phase 1); the jansson assumption → **resolved: removed on master**.

- [ ] **Step 6: §15 — record the conda-libxml2 `.pc` future-todo**

Confirm §15 "Future enhancements" contains the libxml2 `.pc`/headers TODO (already added 2026-06-08; re-add if missing): the `libxml2 <2.14` pin is a workaround for conda 2.14+ shipping runtime-only; future work investigates using a newer conda libxml2 with dev files. Keep the feedstock ref: `https://github.com/conda-forge/libxml2-feedstock/blob/main/build-locally.py`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/condescending-kilby-3c6964
git add docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md
git commit -m "docs(spec): reconcile §6/§8/§13/§15 with Phase 1 validation (pixi pin, no jansson, libxml2<2.14, repo name, libxml2-pc TODO)"
```

---

## Phase 1 Definition of Done

- [ ] `mise run test` and `mise run lint` green (incl. the new version-layout contract test), no warnings.
- [ ] Repo `mise.toml` pins `pixi = "0.70.2"`; `[plugins]` registers `pixi-env` + `vfox-pixi`; `pixi-env` installed; `mise.lock` regenerated.
- [ ] `versions/master/{pixi.toml,pixi.lock,mise.toml}` committed; `pixi.lock` carries the full transitive closure (gnutls→nettle/gmp/p11-kit/libtasn1; libtree-sitter; libxml2 2.13.x); `.pixi/` git-ignored.
- [ ] `versions/master/mise.toml` exposes `EMACS_REF=master` + corrected flags; **both** mise-env-pixi activation **and** direct `pixi run` resolve gnutls/libxml-2.0/tree-sitter.
- [ ] `scripts/configure-check.sh master --build-smoke` is green: configure detects ns/tree-sitter/xml2/gnutls with native-comp **off**; `-nw` launches; `otool -L` shows ncurses → `/usr/lib`, gnutls/xml2/tree-sitter → pixi env.
- [ ] `docs/superpowers/validation-log.md` has the Phase 1 section with **real** results.
- [ ] Spec §6.1/§6.2/§6.5/§8/§13 reconciled + §15 libxml2-`.pc` future-todo recorded.
- [ ] `orchestrator-ci` green on the merge PR (verify the Ubuntu run still passes with `pixi` + `[plugins]` in `mise.toml`; the repo-root `mise install` must not fail on plugin registration — if it does, note it and gate pixi-env behind the Phase-5 macOS runner).
- [ ] Branch `phase-1-reproducible-deps` ready to merge to `main`.

---

## Self-Review (completed by author)

**Spec coverage:** Phase 1 row of §14 → Tasks 1–6. §6.1 pipeline toolchain (pixi pin + plugins) → Task 1. §6.2/§6.4 build-libs pixi PROJECT + transitive lock (D7) → Task 2. §6.5 per-version env → Task 3. §5 "add a version = data" invariant → Task 4. §14 "configure detects ns/tree-sitter/xml2/gnutls, native-comp off; `-nw` on system ncurses; direct-pixi fallback" → Tasks 5–6. Spec drift from validated reality → Task 7. Relocation/bundling/signing/packaging/CI = Phases 2–5 (out of scope by design).

**Placeholder scan:** No TBD/TODO. Generated artifacts (`pixi.toml`/`pixi.lock`) are produced by exact `pixi init`/`add`/`install` commands with explicit verify greps, not hand-authored. The validation-log template's `…` are explicit "fill in real results" markers (filled in Task 6).

**Type/string consistency:** `versions/master/` is the join key everywhere (dir name == `versions.toml` table key == `Manifest.version_input_files/1` arg). `EMACS_CONFIGURE_FLAGS` string is identical in Task 3, the harness, and §6.5 (Task 7). `HAVE_GNUTLS/HAVE_LIBXML2/HAVE_TREE_SITTER/HAVE_NS` + summary wording match `configure.ac` (V10). `missing_version_files/2` and `version_input_files/1` signatures match between `manifest.ex` and `version_layout_test.exs`. pixi env prefix `versions/master/.pixi/envs/default` is consistent across Tasks 2/3/5.

**Decomposition:** Tasks are independently committable; data files (1–3) precede the contract test (4) that asserts them, which precedes the harness (5) and its run (6); spec reconciliation (7) is last and pure-docs. Each task is one focused, signed commit.
```
