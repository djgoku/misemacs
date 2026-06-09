# Validation Log

## 2026-06-08 — Phase 0 / Task 10: mise pixi-plugin path

Environment: macOS arm64, mise 2026.6.1, pixi 0.70.2 (installed via mise). Probes ran in a
throwaway temp dir; pixi invoked ephemerally via `mise x pixi@latest -- …` (no change to the
global mise config). The `mise-backend-pixi` plugin is installed globally as `vfox-pixi`.

### 1. Backend plugin name & prefix — CORRECTION to the plan/spec
- Installing the backend plugin as **`pixi`** (the plan's Task 10 Step 1 / spec §6.1)
  **conflicts with the `pixi` tool** and breaks pixi resolution entirely: `pixi is not a
  valid shim`, and the plugin's own hook fails with `sh: pixi: command not found`.
- Install it as **`vfox-pixi`** (the README default): `mise plugin install vfox-pixi
  https://github.com/esteve/mise-backend-pixi`. After that the `pixi` tool resolves again
  and the backend prefix is **`vfox-pixi:`** (e.g. `mise use vfox-pixi:<tool>`).
- **Action:** fix spec §6.1 — the `[plugins]` entry must be `vfox-pixi = "…"`, not
  `pixi = "…"`; any ad-hoc conda CLI uses the `vfox-pixi:` prefix.

### 2. Backend tool install (`mise use vfox-pixi:<tool>`)
- The backend's hooks shell out to `pixi search` / `pixi global install`, so **pixi must be
  genuinely on PATH** when mise runs the plugin. Under ephemeral `mise x pixi`, the nested
  plugin subprocess did not see pixi. So the backend works once **pixi is an installed/active
  mise tool** (Phase 1 pins pixi in the repo `mise.toml`). Prefix is settled; full
  install-via-backend not exercised here.
- This path is **secondary**: build/runtime C libs use the pixi **PROJECT** (pixi.toml +
  pixi.lock), not the per-tool backend.

### 3. Reproducibility (D7) — CONFIRMED
- A pixi **project** locks the **full transitive closure** in `pixi.lock`. `pixi add gnutls
  libxml2 jansson` (3 top-level deps) produced a `pixi.lock` with **36** conda packages,
  including gnutls's transitive deps **gmp, libtasn1, nettle, p11-kit** (never explicitly
  added). → D7 (bit-reproducible build inputs via pixi) holds.
- `pixi init` on macOS arm64 defaults to `platforms = ["osx-arm64"]` — no `--platform` flag
  needed on the host.

### 4. tree-sitter (v1-optional dep) — KEEP; package name is `libtree-sitter`
- conda-forge has **no** package named `tree-sitter` (`pixi add tree-sitter` → "No
  candidates found").
- The C library is **`libtree-sitter`** (conda-forge, v0.26.9). → KEEP `--with-tree-sitter`
  in v1, sourcing **`libtree-sitter`** in `pixi.toml`. Confirm headers (`tree_sitter.h`) are
  usable at `./configure` time in Phase 1 (conda-forge sometimes splits dev headers).

### Decisions for Phase 1
- Build libs via a pixi **PROJECT** (`pixi.toml` + `pixi.lock`); transitive lock is real (D7 ✓).
- mise-backend-pixi plugin name = **`vfox-pixi`** (NOT `pixi`); backend prefix = `vfox-pixi:`.
  Fix spec §6.1.
- tree-sitter dep in `pixi.toml` = **`libtree-sitter`**; keep `--with-tree-sitter`.

---

## 2026-06-09 — Phase 1: reproducible deps + configure/build validation

Environment: macOS 26.5 arm64, mise 2026.6.1, pixi 0.70.2 (repo-pinned). Build target:
`emacsmirror/emacs` master `a0dc061fa2143e4ae5f62ede039a13a72d382d58` (emacs 32.0.50; no-dash
mirror — identical SHA to `emacs-mirror/emacs`). Validated by `scripts/configure-check.sh master
--build-smoke` (exit 0 under pipefail).

### 1. Dep set & transitive lock (D7) — CONFIRMED
- `versions/master/pixi.toml`: autoconf, automake, pkg-config, texinfo, gnutls,
  **`libxml2 <2.14`**, libtree-sitter. **No jansson.**
- `pixi.lock` (osx-arm64) locks the full closure incl. gnutls's nettle/gmp/p11-kit/libtasn1
  (+ libidn2/libunistring), `libtree-sitter 0.26.9`, `libxml2 2.13.9`. D7 holds.
- **libxml2 pinned `<2.14`:** conda libxml2 2.14+ ships **runtime-only** (`libxml2.16.dylib`, no
  `.pc`/headers); 2.13.9 bundles `libxml-2.0.pc` + headers, so configure's pkg-config check
  resolves the **pixi** libxml2. (Lift-the-pin TODO in spec §15.)

### 2. `--with-json`/jansson REMOVED on master — CONFIRMED
- master `configure.ac` has zero JSON references; flags =
  `--with-ns --without-native-compilation --with-tree-sitter --with-xml2 --with-gnutls`.

### 3. configure feature detection (against the pixi env) — PASS
- `src/config.h`: `HAVE_GNUTLS`, `HAVE_LIBXML2`, `HAVE_TREE_SITTER`, `HAVE_NS` all `#define …1`;
  **`HAVE_NATIVE_COMP` absent** (native-comp off). Summary: window system `nextstep`, native
  lisp compiler `no`.

### 4. Both activation paths — PASS
- **mise-env-pixi** (`_.pixi-env`) and **direct `pixi run` (no plugin)** each resolve
  `pkg-config --modversion gnutls libxml-2.0 tree-sitter` → 3.8.13 / 2.13.9 / 0.26.9. → the
  plugin is NOT load-bearing (direct-pixi fallback confirmed).
- Note: a global `conda:pkg-config` user shim can shadow the pixi env's pkg-config on PATH, but
  it is CONDA_PREFIX-aware and resolves the same pinned versions; the harness forces
  `PKG_CONFIG=$CONDA_PREFIX/bin/pkg-config` under `pixi run` to be deterministic.

### 5. Throwaway build + `-nw` smoke — PASS (with a required build-time rpath)
- `make` → `emacs 32.0.50`; `emacs --batch` runs; **`emacs -nw` launches in a pty** (terminfo
  initialized) → `-nw OK`.
- **Required fix — build-time rpath:** conda dylibs use `@rpath/*` install names; without an
  `LC_RPATH` the **dump step** (`temacs --temacs=pbootstrap`) aborts with
  `Library not loaded: @rpath/libxml2.2.dylib … no LC_RPATH's found`. Added
  `LDFLAGS=-Wl,-headerpad_max_install_names -Wl,-rpath,$CONDA_PREFIX/lib` to configure.
  (Throwaway-validation-only — Phase 2 relocation rewrites these install names + rpath.)
- `otool -L` of the dumped binary: `@rpath/{libxml2.2,libgnutls.30,libtree-sitter.0.26,
  libncurses.6}.dylib` (pixi env); `/usr/lib/{libz,libsqlite3,libSystem,libobjc}` (system).

### 6. ncurses provenance — links from PIXI, not system (DEFERRED to Phase 2)
- The build links **pixi ncurses 6.6** (`@rpath/libncurses.6.dylib`), NOT system
  `/usr/lib/libncurses.5.4.dylib` (system ncurses is 6.0). Root cause: **`texinfo` is the sole
  puller** of ncurses into the env (`pixi tree -i ncurses` → `texinfo`), and pkg-config's
  `-L$CONDA_PREFIX/lib` (needed for gnutls/xml2/tree-sitter) makes `-lncurses` resolve there.
  The three link libs themselves pull no ncurses.
- **Decision (deferred to Phase 2 relocation — its natural home, install_name rewriting):**
  Phase 2 either rewrites `@rpath/libncurses.6.dylib` → system `/usr/lib/libncurses.5.4.dylib`
  (ABI-compatible 6.x) OR bundles it. The harness `[4d]` is informational (records provenance,
  does not gate). spec §6.2's "ncurses = system, verify -nw in Phase 1" updates to: -nw verified
  in Phase 1; system-vs-bundle is a Phase 2 decision.

### Decisions / inputs for Phase 2
- Bundle gnutls/libxml2/tree-sitter (+ gnutls closure) from the pixi env; libz/sqlite/libSystem/
  libobjc stay system.
- ncurses: rewrite-to-system or bundle (above). If "system": separate texinfo (build tool) from
  the link-libs env, or otherwise keep `-L$CONDA_PREFIX/lib` off the `-lncurses` resolution.
- The build-time `-Wl,-rpath,$CONDA_PREFIX/lib` is throwaway; relocation replaces it with an
  `@executable_path/../Frameworks` rpath + rewritten install names.
- Un-fingerprinted host `make`/CLT gap (spec §8) still open — decide in Phase 2.
