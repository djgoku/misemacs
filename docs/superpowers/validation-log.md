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

## 2026-06-11 — Phase 4 (brainstorm): publish mechanics + aqua consumption chain

Environment: gh 2.92.0, mise 2026.6.1, macOS arm64. Lab = throwaway repo
`djgoku/misemacs-phase4-lab` (real `djgoku/misemacs` only read, never written).
Generic gh/mise facts with full proofs live in the knowledge base
(`github-releases.md`, `mise.md`); this section records the project-binding
results (P-numbers referenced by the Phase 4 design spec).

### 1. `gh release create` collision semantics (closes the §13 open question)
- Existing **release** → exit 1, stderr `a release with the same tag name
  already exists: <tag>` (P1; the machine-checkable `.N` retry signal).
- Existing **tag without a release** (after `gh release delete`, which keeps
  the tag) → exit 0, the release silently adopts the dangling tag at its old
  commit (P2). ⇒ the publisher's tag snapshot must be the UNION of git tags and
  release tag-names, so dangling tags yield `.N+1` instead of adoption.
- `gh release delete <tag> --yes --cleanup-tag` removes release AND tag in one
  step, exit 0 (P12) — the validated real-repo cleanup path for G2.

### 2. The Latest marker (the outward-facing trap)
- Creating a release with NO `--latest` flag **steals the Latest marker**
  (GitHub `make_latest` defaults true): a dash-tag lab release auto-became
  Latest over the incumbent (P3). ⇒ `pipeline/publish` always passes
  `--latest=false`; flipping is `pipeline/promote`'s explicit
  `gh release edit <tag> --latest` (validated to work, also as the rollback).
- Drafts create NO git tag (`untagged-…` URL) and are invisible without auth ⇒
  never aqua/mise-installable (P4; eliminates draft-based E2E). Prereleases
  create the real tag, are public, never auto-Latest, hidden from
  `mise ls-remote`, but installable by exact `@tag` (P5).
- Asset re-upload to a release needs `--clobber` (else exit 1) (P6).

### 3. Consumption chain — how `mise use aqua:djgoku/misemacs@<tag>` resolves
- Mechanism (from the old-system README, the documented user path):
  `MISE_AQUA_REGISTRY_URL=https://raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml`
  — a SINGLE-FILE registry served from the misemacs repo itself (NOT the
  `djgoku/aqua-registry` fork branch, which is just a PR-shaped copy with
  identical contract values). Without the env var, `mise ls-remote
  aqua:djgoku/misemacs` fails: `no aqua-registry found for djgoku/misemacs`
  (baked registry lacks the package; upstream `pkgs/djgoku` is 404). ⇒ the
  fresh take MUST carry `aqua/registry.yaml` at the same path or the cutover
  push breaks every configured install (P7 → spec G5).
- Full chain validated against the lab registry (fresh `MISE_DATA_DIR` +
  `MISE_CACHE_DIR` + empty global config): template render → download →
  extract → contractual layout; **aqua's `{{.Arch}}` token = `arm64`** on
  darwin/arm64 (closes the Phase-0 `Naming` ARCH-NOTE canary) (P7).
- **`@latest` = GitHub's latest-release MARKER**, not version sort: with the
  marker on the dot-tag, `mise latest` returned it; after
  `gh release edit <dash-tag> --latest`, a fresh-cache resolve returned the
  dash tag (P8). Dot/dash tags coexist harmlessly (sort order only affects
  `ls-remote` listing). Gotcha: `MISE_CACHE_DIR` is independent of
  `MISE_DATA_DIR` — a warm cache serves a stale `latest` within its TTL.
- **mise 2026.6.1 does NOT verify `SHASUMS256.txt`**: install succeeded with a
  deliberately corrupted checksum asset; debug shows `using GitHub API digest
  for checksum verification` (GitHub's per-asset digest) and no SHASUMS fetch
  (P9). ⇒ `pipeline/package` must self-verify (`shasum -c`); the file remains
  required by the registry contract (real `aqua` CLI) + as audit artifact.
- Proven `SHASUMS256.txt` format (the release installed on this machine):
  `shasum -a 256` output, tarball-only (P14).

### 4. Legacy coexistence on the real repo (read-only survey)
- Legacy releases are dot-dated (`emacs-master-2026.06.05` = current Latest)
  with assets `build-manifest.org`, `inputs.sha256`, tarball, `SHASUMS256.txt`
  — **no `build-manifest.json` anywhere** ⇒ the new system's first run is the
  designed `first_run` base case (§7.2/§8) against the live repo (P10).
- The fresh take has NO git remote; remote main still serves the old system.
  `gh --repo` publishes from anywhere; release-created tags point at the remote
  default-branch HEAD until the cutover push — cosmetic, the tag is an
  artifact handle (P13).

### 5. Determinism probe (G4: defer byte-reproducibility)
Same built tree tarred twice (1.1 s apart, `COPYFILE_DISABLE=1 tar
--no-xattrs`) → **identical** sha256; recreated tree (fresh mtimes) →
different sha256 (P11). Bytes are stable per artifact, rebuilds differ anyway
⇒ reproducible-tar engineering deferred; xattr-free flags kept (E7).

## 2026-06-13 — Phase 4 (implementation): lab rehearsal + real-repo E2E (the §14 DoD)

Executed via the subagent-driven plan; the real 150 MB Phase-3 artifact
(`build/master/Emacs.app`, upstream `8decb65`) reused throughout. Every
real-repo step has a passing lab twin.

### 1. Lab dress rehearsal (djgoku/misemacs-phase4-lab, public, real artifact)
- Reset to 0 releases/0 tags; lab `aqua/registry.yaml` set to the 4-file vendored
  shape (repo_name swapped) via the gh contents API.
- `mise run publish --repo …-lab` → `emacs-master-2026-06-13` created
  `--latest=false`; assets = tarball + `SHASUMS256.txt`; package self-verify
  (layout, `shasum -c`, extract `--batch` `ok 32.0.50`, sentinel codesign,
  zero `cs.`/quarantine xattrs) all green.
- **Clean-box VM e2e (pregate `--cmd`, fresh tahoe VM, fresh MISE_DATA/CACHE):**
  `mise use aqua:djgoku/misemacs-phase4-lab@<tag>` → download/checksum/extract →
  `E2E-BATCH-OK 32.0.50`, `E2E-GUI-OK`, `E2E-EMBEDDED-SIGS-OK`,
  `E2E-NO-QUARANTINE`, `e2e: PASS` (`✅ macos`).
- `mise run promote --repo …-lab --tag <tag>` → `build-manifest.json` attached
  (schema 1, `Core.Hash` fingerprint `sha256:8f45a68d…`), Latest flipped;
  fresh-cache `mise latest` resolved `<tag>` (P8).

### 2. The Latest-marker semantics (corrects a plan expectation)
The plan's Step-3 "expect 404 for `releases/latest` with one `--latest=false`
release" was WRONG: `GET /releases/latest` falls back to the most-recent
published release when **none** is flagged `make_latest`, so the sole
`--latest=false` release is returned. The real safety property is
**incumbent preservation**, re-confirmed live on the lab: with a release
explicitly flagged latest, creating a NEWER-dated `--latest=false` release left
the marker unmoved (matches brainstorm T5). This is the property the real repo
relies on.

### 3. Real repo (djgoku/misemacs — both gates user-approved; G2 lifecycle)
- **Gate A → publish:** `MISEMACS_PUBLISH_OK=1 mise run publish --repo
  djgoku/misemacs` → `emacs-master-2026-06-13` created `--latest=false`
  (dash tag coexists with the legacy dot-tags). `@latest` stayed
  `emacs-master-2026.06.05` immediately after.
- **E2E (the §14 DoD): PASS** — pristine VM, real consumed registry URL
  (`raw…/djgoku/misemacs/main/aqua/registry.yaml`, the old-system file whose
  contract is identical, P7): `mise use aqua:djgoku/misemacs@emacs-master-2026-06-13`
  → `E2E-BATCH-OK 32.0.50`, `E2E-GUI-OK`, `E2E-EMBEDDED-SIGS-OK`,
  `E2E-NO-QUARANTINE`, `e2e: PASS`. `@latest` unchanged throughout.
- **Gate B → cleanup:** `gh release delete emacs-master-2026-06-13 --cleanup-tag`
  → tag count 0, release count 0, `@latest` still `emacs-master-2026.06.05`,
  release list = legacy only. **Repo byte-identical to its pre-Phase-4 state
  (G2).** First *kept* release ships with Phase-5 automation.

### 4. Full pregate (fresh macOS VM, integrated recipe)
- First run FAILED at `pipeline/build-emacs`: `versions/master/mise.toml … not
  trusted`. Root cause: `.pregate/common.sh` trusted only the repo-root config;
  the host had the per-version config trusted, masking the gap in earlier
  phases (so the in-VM build-from-source was never truly exercised before).
  Fix: `common.sh` now trusts each `versions/*/mise.toml` (glob → "add a version
  = data only"). Re-run **green**: `Result: 75 passed` → build → relocate →
  `cleanroom: PASS` → `package master pregate-smoke` PASS against a freshly-built
  app (`ok 32.0.50`, upstream `4a86a530`). pregate green = CI-green by construction.

### 5. tart disk caution — CLEARED on this host
Three VM runs (lab e2e + 2 full pregates) at host Data volume **94–95 % full /
~54 GB free** — squarely in `~/.claude/knowledge-base/tart.md`'s caution band —
produced **zero** clone truncation or false failure (all clones ran intact;
build-from-source completed). Empirical evidence the byte-count caution is
over-conservative when guest writes are flushed (pregate already `sync`s); the
KB note is being relaxed accordingly.

## 2026-06-14 — Phase 5 (automate): implementation + throwaway validation

Spec `docs/superpowers/specs/2026-06-13-phase-5-automate-design.md`, plan
`…/plans/2026-06-13-phase-5-automate.md`. Implemented via subagent-driven
development (Tasks 1–12) on branch `phase-5-automate`; full DoD validated on the
public throwaway `djgoku/misemacs-phase5-lab` (deleted post-cutover). The real
repo was never touched.

### 1. Implementation — 13 commits, 104 ExUnit green
New Elixir behind behaviours: `Toolchain`(+Macos CLT/SDK fingerprint, Decision E),
`Upstream`(+GitLsRemote), `Releases`(+Gh); pure `Orchestrate.{decide,finalize}_outputs`;
`mix orchestrate.{decide,finalize}`; `Hash.toolchain_hash/3`; `Manifest.versions!/merge`;
`Decide.force/3`; `release.manifest --clt-fingerprint`. Bash: `publish` writes
`published-tag.txt`; `promote --manifest`. `targets.toml` runner=`macos-26`; mise tasks
`decide`/`finalize`; `.github/workflows/daily.yml` (decide→build→finalize).
- Per-task (combined spec+quality) reviews + a final whole-branch opus review.
- **Decision-E invariant EMPIRICALLY PROVEN**: `mix orchestrate.decide` (detect) and
  `mix release.manifest` compute a **bit-identical `inputs_hash`** over the same root/clt/sha
  (ran both paths; `sha256:8238032d…`) ⇒ no daily rebuild-storm.
- Review caught a real bug: `System.cmd` **raises** `ErlangError(:enoent)` on a missing
  binary — a `case … _ -> nil` only catches a nonzero *exit*, not the raise. Added
  `rescue ErlangError` to the `Releases.Gh`/`Upstream.GitLsRemote` adapters (commit `8f5eec0`)
  so an absent `gh`/`git` degrades to `nil` (the self-heal contract) instead of crashing.

### 2. Five CI bugs found by the throwaway BEFORE the real repo (each ~2-min fast-fail)
1. **`jdx/mise-action@v2`** constructs an outdated mise download URL → 404 → bumped to **@v4**
   (and all actions to latest majors: checkout v6, cache v5, upload-artifact v7, download-artifact v8).
2. **mise `2026.6.7` shipped ZERO macos-arm64 assets** (a broken release; `2026.6.6` has the full set)
   → pin `version: 2026.6.6` in mise-action. (→ KB)
3. **mise-action@v4 auto-runs `mise install --locked`** when a `mise.lock` is present, which
   **aborts** because `core:erlang` is source-compiled and has no lockfile URL. Fix: `install: false`
   + a plain `mise install` step (what `@v2` did). The action's `shouldUseLockedInstall()` only
   skips `--locked` when `tool_versions`/`mise_toml` is set or no lock file exists — there is no
   "disable locked" input. (→ KB mise.md)
4. **daily.yml jobs run `mix` tasks without `mix deps.get`** (unlike the `test` task) → fresh
   runners hit "unchecked dependencies". Fix: a per-job setup step `mise install` + `mix deps.get`.
5. **The `decide` step piped `mise run decide` straight into `$GITHUB_OUTPUT`** via `tee`; the
   first-run **`mix compile` noise** (the toml dep's Elixir-1.20 type warnings, "Compiling N files")
   went into the output file → `##[error]…Value cannot be null (name)`. Fix: capture to a temp file,
   `grep -E '^(matrix|any|dry_run)='` → `$GITHUB_OUTPUT` (finalize/dry-run paths already use `sed -n '/p'`).

### 3. T1–T10 + consumer DoD — all PASS on real macos-26 runners
- **T6/T1/T2/T5/T10 + full pipeline** (run 27502509167): first_run → `decide` emits the matrix on
  macos-26 → `build` (build/relocate/sign/package/publish) → `finalize` merge + flip. First release
  `emacs-master-2026-06-14` is **Latest** with `…-macos-arm64.tar.gz` (63 MB) + `SHASUMS256.txt` +
  `build-manifest.json` (`inputs_hash sha256:d10171…`, `upstream_sha ca44dce1`, `released_tag`).
- **T9 idempotency (§14 DoD)**: 2nd same-day run → `matrix={"include":[]}`, `any=false` → build +
  finalize **skipped**, release count unchanged.
- **Consumer install (§14 DoD)** — fresh macOS VM, `mise use aqua:djgoku/misemacs-phase5-lab@<tag>`:
  download/checksum/extract → `E2E-BATCH-OK 32.0.50`, GUI, `E2E-EMBEDDED-SIGS-OK`, `E2E-NO-QUARANTINE`,
  `e2e: PASS` (101 s).
- **T8 force**: 2 dispatches → `.1`/`.2` (real same-day `.N` collision). **T8 dry-run** (PR touching
  `versions/master/mise.toml`): build → `dryrun-master-macos-arm64` 62 MB artifact, **finalize skipped,
  NO release** (count stayed at .1/.2).
- **T3 concurrency**: two same-cell force builds **serialized** by `concurrency: build-master-macos-arm64`
  (cancel-in-progress:false) — B ran 16:33:52–16:41:02, then A 16:41:05–16:48:07 (3 s after B; zero overlap).
- **T4 schedule**: a `schedule` tick fired from the default branch (17:03 from a 16:39 cron, GitHub
  cron lag ~24 min) → detect mode → `any=false` → skip. Confirms cron-from-default-branch (the
  cutover-last activation).
- **T7 caches**: cold first build, then **~6-min warm builds** (mise-action tool cache for
  erlang/elixir/pixi + the `pixi-env` `actions/cache`). Build perf far better than the ~40-min estimate.

### Phase-5 status
Implementation + the entire T1–T10 + consumer DoD are validated. The CI fixes above (and a
`build(orchestrator)` switch of the `toml` dep to `github:bitwalker/toml-elixir@e32c899` — locally
green but lab-validated on hex `0.7.0`, and that ref does NOT clear the type warnings) are on the
branch. Remaining = the user's: a signed cutover push of `phase-5-automate` → `djgoku/misemacs` `main`
(cron activates by construction), then delete the lab. A few branch commits are unsigned (re-signed at
the cutover squash/merge).

## 2026-06-28 — Bundled enchant payload (spec 2026-06-25, plan 2026-06-28; branch enchant-task6)

Spec: `docs/superpowers/specs/2026-06-25-bundled-enchant-payload-design.md`. All claims below were
verified empirically on macOS arm64 against the **real git-source-built feedstock enchant 2.8.2**
(not synthetic fixtures), staged via `Orchestrator.Payload.Enchant` into a mock bundle, then probed
with the conda env **moved aside** (cleanroom = no system/build enchant present).

### 1. Phase 0 — git-source via pixi-build (supersedes "publish to a channel")
`enchant = { git = "https://github.com/djgoku/enchant-feedstock", branch = "misemacs-recipe",
subdirectory = "recipe" }` + `[workspace] preview = ["pixi-build"]` → `pixi install` **builds** the
real feedstock enchant (the `pixi-build-rattler-build` backend, on conda-forge). Produces both
providers (`lib/enchant-2/enchant_{applespell,hunspell}.so`) + the `dladdr` self-relocation
constructor; `enchant-lsmod-2` lists both. `pixi.lock` pins the git commit (`2de3177…`). No
anaconda/prefix.dev account. Both `versions/{master,emacs-31}/pixi.lock` re-locked to that commit.

### 2. Findings 1 & 2 — root cause (the handoff's Finding-2 hypothesis was WRONG)
- The reported `enchant-2 -l -d en_US` **SEGFAULT** and `enchant_broker_dict_exists("en_US")=0` are
  **one bug**: `stage_copy` dropped the feedstock's `share/enchant-2/AppleSpell.config` (applespell's
  locale map). Without it applespell claims no locale → `dict_exists=0` → enchant falls back to the
  bare language tag `en` → flaky **upstream applespell NULL-deref**. lldb (cleanroom): `enchant_dict_finalize`
  (`x0=NULL`, `ldr [x0,#0x60]`) ← `enchant_dict_unref` ← `enchant_broker_new_dict` ←
  `appleSpell_provider_request_dict(tag="en")` @ `providers/applespell_checker.mm:304` ← `main`. So
  the crash is in **applespell** (tried first per ordering), NOT the dict-less hunspell fallback.
  Memory-safety / heap-state-dependent: pristine source env `-d en` returned exit 139 then exit 1.
- **Fix (verified, real artifact, cleanroom):** `stage_copy` now copies `AppleSpell.config` →
  `dict_exists("en_US")=1`, `request_dict` succeeds, `check("helllo")=1`, `-a` suggests
  (`& helllo 2 0: hello, he'll`); en_GB also works; `enchant-2 -l -d en_US` exits 0 (no crash).
  *Residual:* the bare-`en` upstream crash stays latent (only if a caller requests `en` with no
  region) — recommend a feedstock patch to `applespell_checker.mm` as a follow-up; region tags safe.
- **Decision C → applespell default, zero bundled dictionaries; hunspell is bring-your-own.** The
  AppleSpell.config fix (above) makes applespell check + suggest `en_US`/`en_GB` with no dict files,
  so the default path needs nothing extra. We evaluated bundling a permissive **SCOWL/LibreOffice
  `en_US` hunspell dict** but **decided against it** — applespell covers the default and a ~50k-line
  `.dic` adds license-tracking + repo/diff bloat for the secondary path. The hunspell provider still
  ships; a user enables it by dropping their own `en_US.aff`/`.dic` into `~/.config/enchant/hunspell/`
  (the per-user dir the provider searches: `g_get_system_data_dirs()/hunspell` +
  `~/.config/enchant/hunspell` — **not** the enchant prefix, since dladdr does not reach dict lookup).
  No global env mutation (O5); BYO activation is documented in the README.

### 3. Finding — build-prefix `leak_check` DROPPED
`verify/3`'s `strings`-grep for the conda prefix false-flagged 6 legitimately-relocated dylibs
(libenchant, providers, glib/gio/intl) — real conda dylibs bake the install prefix into **inert
data-section strings** `install_name_tool` cannot strip. The macho self-containment gate (load
commands) + per-file `codesign --verify --strict` + the functional cleanroom run are the real proof;
`dladdr` overrides any compiled-in prefix at runtime. Removed from `verify/3` (and the cleanroom
`strings|grep` step is NOT added). Confirmed: staged real enchant now passes `verify/3` (`:ok`).

### 4. O-items resolved
- **O2 — pkg-config shim chosen** (not bundling real `pkgconf`): the shim is minimal, fully controls
  flags incl. `-Wl,-rpath`, refuses non-`enchant-2` queries (exits non-zero), and is `exec-path`-scoped
  to jinx's compile by `site-start.el` — never shadows a real system `pkg-config`. The real
  `${pcfiledir}`-relative `.pc` still ships for non-jinx consumers.
- **O5 — `site-start.el` keeps auto-load** but is discovery-only: no `DYLD_*`, no policy
  (`ispell-program-name` untouched); its only effect is `with-eval-after-load 'jinx` advice. Opt out
  with `(setq misemacs-enchant-disable t)` or `emacs -Q` / `--no-site-file`.
- **O6 — resolved** (applespell checks+suggests en_US/en_GB once `AppleSpell.config` staged); hunspell
  is bring-your-own (no bundled dict).
- **O8 — confirmed:** the built env's `share/enchant-2/enchant.ordering` is the ordering path (our
  staged `*:applespell,hunspell` overrides the feedstock default `*:hunspell,nuspell,aspell`).
