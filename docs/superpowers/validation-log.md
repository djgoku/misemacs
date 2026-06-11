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

---

## 2026-06-10 — Phase 2: build + relocation (the crux)

Environment: macOS 26.5 arm64, mise 2026.6.1, pixi 0.70.2 (repo-pinned), elixir 1.20.0-otp-29,
Apple clang. Built + relocated `emacsmirror/emacs` master → **emacs 32.0.50**.

### 0. Tooling split (decision) — hybrid bash build + Elixir relocation
- **Build = bash** (`pipeline/build-emacs`): pixi env + autogen/configure/make/install — shell's home turf.
- **Relocation + gate = Elixir** in the orchestrator (`Orchestrator.Macho` pure classify/relpath/parse/
  gate_violations + `Macho.Tool` behaviour & `Macho.Otool` IO adapter + `Orchestrator.Relocate` runner +
  `mix relocate` task), per spec D4/§7.1 (pure core + IO adapter, ExUnit). Replaces an initial bash
  `lib/macho.sh` (the bash version hit a space-truncation parsing bug — a symptom of bash being the wrong
  tool for structured otool output). Pure tests run everywhere; the real-binary integration test is
  `@tag :macos` (orchestrator CI is ubuntu — `test_helper.exs` excludes `:macos` off Darwin).

### 1. Build (`pipeline/build-emacs`) — PASS
- `--with-ns` + `make install` produces a **self-contained `nextstep/Emacs.app`** in the build tree
  (no `--prefix` needed; the assumption held — no script adjustment). Located via `find -maxdepth 3
  -name Emacs.app`, copied to `build/master/Emacs.app`.
- Build needs `LDFLAGS=-Wl,-headerpad_max_install_names -Wl,-rpath,$CONDA_PREFIX/lib` (the rpath is the
  Phase-1 dump-step finding; relocation deletes it). `--batch` → `ok 32.0.50`.
- Pre-reloc `otool -L` of the main binary: `@rpath/lib{gnutls.30,xml2.2,tree-sitter.0.26,ncurses.6}.dylib`
  + system `/usr/lib/{libSystem.B,libobjc.A,libz.1,libsqlite3}`.

### 2. Relocation (`Orchestrator.Relocate`) — generic Mach-O closure walk, PASS
- BFS copies the full non-system (`@rpath/*` + foreign-absolute) dylib closure into `Contents/Frameworks`,
  sets ids to `@rpath/<base>`, rewrites foreign-absolute refs to `@rpath`, gives each Mach-O a
  depth-correct `@loader_path/<rel>` rpath, deletes the build-time `$CONDA_PREFIX/lib` rpath.
- **Real Frameworks closure = 17 dylibs** (bigger than the spec sketch): gnutls, nettle, hogweed, gmp,
  p11-kit, tasn1, idn2, unistring, **libffi, iconv, intl, lzma, libtinfo**, ncurses, tree-sitter, xml2,
  **libz**. The generic walk correctly bundles conda's own `libz.1.dylib` (referenced `@rpath` by conda
  libs) even though the Emacs main binary links `/usr/lib/libz.1.dylib` — both resolve independently.
  ncurses bundled generically (`libncurses.6` + `libtinfo.6`); **`-nw`/terminfo out of scope** (§15).

### 3. Signing (Decision C) — deep ad-hoc bundle sign, FIXED from per-Mach-O
- **Bug found on the real bundle:** per-file `codesign -s - -f <Contents/MacOS/Emacs>` (the bundle main
  executable) triggers codesign *bundle mode*, which fails on unsigned nested helpers
  (`Contents/MacOS/libexec/rcs2log`, a script). The fake fixture (no Info.plist, no nested non-Mach-O
  helpers) never hit this.
- **Fix:** a single `codesign --force --deep --sign - <Emacs.app>` once at the end, after all
  `install_name_tool` edits (`Macho.Tool` `resign/1` → `sign_bundle/1`). Validated: rc 0;
  `codesign --verify --deep` → "valid on disk / satisfies its Designated Requirement". Fixture upgraded
  to a real bundle (Info.plist + nested `libexec/helper.sh`) that reproduces + guards the regression.

### 4. The gate (`Macho.gate_violations`) — PASS on the real app
- Asserts: no foreign dependency path, no foreign LC_RPATH, every `@rpath/<lib>` present in Frameworks.
- On `build/master/Emacs.app`: **PASS** — zero `.pixi`/homebrew/usr-local refs across every Mach-O;
  main binary rpath = `@loader_path/../Frameworks` only.

### 5. Clean-room (no-pixi) proof — PASS, locally, no VM needed
- `mise run cleanroom` moves the **entire** `versions/master/.pixi` env aside, then launches the
  relocated app. Result: `--batch` → `ok 32.0.50` (full dylib closure resolved from `Contents/Frameworks`
  alone), **GUI frame smoke OK**, `emacsclient`/`etags`/`ebrowse` run; `.pixi` restored via `trap`.
- **Clean-room mechanism = pregate, not a bespoke script.** `.pregate/macos.sh` runs build → relocate →
  gate → `mise run cleanroom` ALL in the one fresh disposable macOS VM (fresh OS + toolchain, pixi env
  moved aside). No second/nested VM (Apple Virtualization doesn't nest), no `sshpass`, no 50-80GB image
  pull. The static gate + the moved-aside fixture test + this real-app moved-aside run together establish
  self-containment without a separate pristine VM.

### Decision E — host make/CLT fingerprint gap (spec §8): RESOLVED (record now, wire Phase 5)
Fold `xcode-select -p` + `clang --version` (the CLT/SDK build string) into `toolchain_hash` when the
fingerprint is consumed (Phase 5). A runner-image CLT/SDK bump then rebuilds all refs. No Phase-2 code.

### rpath scheme (refines spec §9)
Build-time `-rpath,$CONDA_PREFIX/lib` (for the dump step) is deleted by relocation; relocation adds a
depth-correct `@loader_path/<rel-to-Frameworks>` rpath to every Mach-O (not the spec's
`@executable_path/../Frameworks` sketch). Signing is a single deep ad-hoc bundle sign, last.

---

## 2026-06-11 — Phase 3: signing (validation-driven; Decision F)

Environment: macOS 26.5 (25F71) arm64, Gatekeeper "assessments enabled". Full
proofs in `~/.claude/knowledge-base/macos-gatekeeper.md`; summarized here because
the repo docs must stand alone.

### 1. Quarantine/Gatekeeper evidence — ad-hoc IS sufficient for the aqua/mise path
- **E1 — the real install path is quarantine-free:** both `mise use
  aqua:djgoku/misemacs` installs under `~/.local/share/mise/installs/` have ZERO
  `com.apple.quarantine` xattrs anywhere (`find … -exec xattr -l` → 0 hits); the
  ad-hoc apps run. Gatekeeper only assesses quarantined files ⇒ it never sees us.
- **E2 — curl sets no quarantine** (real release asset downloaded; no such xattr).
- **E3 — CLI `/usr/bin/tar` does not propagate quarantine** from a quarantined
  tarball (xattr verified on the archive; absent on extracted files). Finder/
  Archive Utility extraction untested — assumed quarantining; out of scope.
- **E4 — quarantined ad-hoc code IS blocked:** a fresh never-executed ad-hoc
  binary with `com.apple.quarantine` (0081 and Safari-style 0083) hangs/denied at
  exec; its unquarantined twin runs. So browser-download distribution would NOT
  work today — that is the Developer-ID trigger, not a v1 problem.
- **E5 — `spctl -a -t exec` "rejected" ≠ broken:** the ad-hoc Emacs.app is
  policy-rejected while `codesign --verify --deep --strict` passes; policy only
  applies to quarantined files (E1–E3).
- **E6 — Gatekeeper caches approval by cdhash:** quarantining an already-run
  binary does not block it. (Testing gotcha: GK experiments need fresh binaries.)

### 2. Transport proof — the ad-hoc bundle runs on a machine that never built it
- Mechanism: pregate `--cmd` into a fresh `macos-tahoe-base` VM (empty
  Gatekeeper/cdhash cache = a true "second arm64 Mac"); working tree piped in
  with the relocated app at `build/master/` via pregate's xattr-stripping
  `COPYFILE_DISABLE=1 tar --no-xattrs` — the same xattr-losing class of
  transport as the real channel (aqua's Go tar extraction).
- **RESULT: PASS** — in the guest: `--batch` printed `32.0.50`;
  `codesign --verify --strict` PASSED on individual Mach-O files post-transport
  (`Contents/Frameworks/libgnutls.30.dylib`, `Contents/MacOS/bin/emacsclient`,
  → `EMBEDDED-SIGS-OK`); GUI frame smoke → `GUI-OK`.
- Bundle-level `codesign --verify --deep --strict` in the guest: **FAIL,
  expected and root-caused** (E7 below) — "code object is not signed at all /
  In subcomponent: …/Contents/MacOS/libexec/Emacs.pdmp" (exit 1). The first
  (uncorrected) proof run asserted exactly this and "failed"; systematic
  debugging turned it into E7 rather than a Developer-ID pivot.

### 3. E7 — `--deep` xattr-signs non-Mach-O nested code; tar strips it; launch doesn't care
- The deep ad-hoc sign stores signatures for the bundle's only two non-Mach-O
  nested-code files (`Contents/MacOS/libexec/Emacs.pdmp`, `…/rcs2log`) in
  `com.apple.cs.{CodeDirectory,CodeRequirements,CodeSignature}` XATTRS (full-
  bundle xattr inventory: exactly those two). Embedded Mach-O signatures are
  content-borne and unaffected.
- Any xattr-stripping transport (pregate's tar flags; aqua's Go extraction,
  which never restores macOS xattrs) drops them ⇒ bundle-level
  `codesign --verify` fails — deep AND non-deep, and even pointed at the main
  executable (bundle mode kicks in). Control: a default bsdtar round trip
  (xattrs ride in PAX headers) verifies clean — single-variable proof.
- Launch is unaffected: the stripped app runs `--batch` on the host and in the
  pristine VM (+ GUI) — arm64/AMFI consult only embedded Mach-O signatures.
  Ground truth: the SHIPPED aqua-installed release on this machine has zero
  `com.apple.cs.*` xattrs, FAILS deep verify ("code has no resources but
  signature indicates they must be present"), and runs fine — post-install
  bundle verification was never a property of this channel.
- Consequences: (1) full-bundle codesign verification is a BUILD-TIME invariant
  (`verify_bundle`, §5 below), asserted before packaging — never a post-install
  check; (2) transported integrity is checked per-Mach-O (non-main-exe files
  don't trigger bundle mode); (3) Phase 4 should create the release tarball
  WITHOUT xattrs deliberately (deterministic assets; consumers lose them
  anyway — spec §10); (4) a future Developer-ID path that wants post-install
  verification must also switch the download container to an xattr-preserving
  format (dmg/zip) — spec §15.

### 4. Decision F — ad-hoc sufficient for v1; Developer ID + notarization DEFERRED
Grounds: E1–E5 + the transport proof. Entitlements/hardened runtime: not needed
(notarization-era concerns; ad-hoc carries neither). Revisit triggers (any one):
browser-download installation becomes a goal; a macOS release quarantines the
aqua/mise path or tightens exec policy; enterprise/MDM rejections reported.
Deferred-path seam: swap the `-` identity in `Macho.Tool.sign_bundle/1` for a
cert from CI secrets + `--options runtime` (+ entitlements if Emacs's dumper
needs them) + a `notarytool submit --wait`/`stapler staple` stage between sign
and package — gated on secret presence so contributor builds stay ad-hoc.

### 5. verify_bundle invariant (the one Phase-3 code change)
`Orchestrator.Relocate.run/3` now fails with `{:error, {:signature_invalid, …}}`
unless `codesign --verify --deep --strict` passes after the deep ad-hoc sign
(`sign_gate: PASS/FAIL` alongside `macho_gate`). Validated: tampering a sealed
Frameworks dylib post-sign → "main executable failed strict validation /
In subcomponent: …" (regression-tested with a tamper-after-sign tool stub in
`relocate_test.exs`). Runs at relocation time — before packaging — where the
xattr-borne signatures (E7) are still intact, so the full deep verify is
meaningful there and only there.
