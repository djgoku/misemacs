# Bundled enchant payload — design spec

*Status: draft for review (2026-06-25). Branch: `enchant`.*

## 1. Summary

Ship **enchant** (the spell-checking abstraction library) *inside* every misemacs
`Emacs.app`, relocated so it resolves entirely from within the bundle, so that
**[jinx](https://github.com/minad/jinx) compiles and runs on a clean macOS machine**
(no Homebrew, no system enchant) — exactly the "self-contained app, clean machine"
promise misemacs already makes for Emacs's own dylib closure.

This is the first instance of a general idea — **companion native payloads bundled
into the app** — but we deliberately build *only enchant* now, behind a thin seam, not
a payload framework (see §4, Decision G).

enchant is consumed two ways, both supported by this payload:
- **jinx** (primary) — a dynamic module jinx compiles *on the user's machine on first
  load*, linking `libenchant-2`. Needs runtime libs **and** build-time headers + a way
  for jinx's `pkg-config enchant-2` to resolve into the bundle.
- **`ispell.el`** (free bonus) — via the on-`PATH` `enchant-2` CLI
  (`ispell-program-name "enchant-2"`). Runtime-only; opt-in by the user.

## 2. Scope

**In scope (v1):**
- macOS `arm64` only (matches misemacs v1).
- enchant **2.8.2** from `djgoku/enchant-feedstock@misemacs-recipe`, with **hunspell +
  applespell** providers; **applespell is the default backend**.
- **applespell default (license-free OS spell-checker); hunspell is present but bring-your-own**
  — no dictionaries are bundled (Decision C). The feedstock's
  `share/enchant-2/AppleSpell.config` (applespell locale map) is staged — **required**, else
  applespell claims no locale and enchant crashes on the bare-language fallback (§13).
- Runtime libs + SDK (headers + relocatable `.pc` + a jinx `pkg-config` shim) + a tiny
  `site-start.el` so jinx compiles against the bundle automatically.
- Applies to **all channels** (`master`, `emacs-31`) — it is the same payload for every
  Emacs version.

**Out of scope / deferred:**
- pinentry and any "gpg stack" companion (parked; separate spec/session).
- native-comp, more arches/OSes, Developer-ID/notarization (inherit misemacs v1 limits).
- Pre-compiling jinx's module inside the build (we ship ingredients, not jinx itself).
- A non-Apple default backend, or bundling any hunspell dictionaries (hunspell is bring-your-own).

**Phase 0 — RESOLVED to git-source (no channel publish):** pixi builds the real feedstock
enchant straight from the git branch via `pixi-build` (`enchant = { git = ".../enchant-feedstock",
branch = "misemacs-recipe", subdirectory = "recipe" }` + `[workspace] preview = ["pixi-build"]`).
Verified 2026-06-28: produces both providers + the `dladdr` self-relocation; `pixi.lock` pins
the git commit (reproducible). This supersedes the original "build + publish to a conda channel
(prefix.dev)" plan — no anaconda/prefix.dev account needed. Tradeoff: the source build re-runs in
a fresh env (CI rebuild cost); build-inline-in-pipeline remains the fallback if that bites.

## 3. Background — how the Emacs relocator works today

`Orchestrator.Relocate.run/3` (`orchestrator/lib/orchestrator/relocate.ex`):
1. **Globs every Mach-O physically under the app** (`app/**`, filtered by `macho?`) — it
   does *not* start from Emacs's link closure.
2. Walks each one's `otool -L` deps; copies every **foreign** dylib (and `@rpath/*`) into
   `Contents/Frameworks` (flat, by basename); sets each copy's id to `@rpath/<base>`.
3. Rewrites every foreign dep ref → `@rpath/<base>`; adds a depth-correct
   `@loader_path/<relpath-to-Frameworks>` rpath (`Macho.relpath/2`, handles arbitrary
   subdir depth); deletes the foreign (conda) rpath.
4. **Deep ad-hoc signs the whole bundle once** (`codesign --force --deep --sign -`),
   verifies, then **gates** with an otool self-containment check
   (`Macho.gate_violations/2`): no foreign deps, no foreign rpaths, every `@rpath/<base>`
   present in `Frameworks`.

`Macho.classify/1` leaves `/usr/lib/*` and `/System/*` **system** refs alone — so
applespell's AppKit/Cocoa references are correctly *not* bundled.

Packaging (`pipeline/package`) tars the app **after** relocate+sign, so anything staged
into the app before relocate rides along with **no packaging change**.

## 4. Key decisions

- **A — Delivery: in-bundle.** enchant lives inside `Emacs.app`; no sidecar install. Keeps
  misemacs's "one artifact, clean machine" promise.
- **B — Consumer scope: Runtime + SDK.** Ship libs, providers, headers, a relocatable
  `.pc`, and a jinx-resolving shim so jinx compiles itself on first load. We do **not**
  adopt jinx as a build artifact (rejected "pre-build the module" — couples a third-party
  ELPA package's C module + release cadence into the Emacs build).
- **C — Backend: applespell default, zero bundled dictionaries; hunspell is bring-your-own.**
  macOS-only ⇒ the OS spell-checker is always present, multilingual, license-free — applespell
  stays the default and (with the staged `AppleSpell.config`) checks + suggests `en_US`/`en_GB`
  correctly with **no dictionary files required**. The hunspell provider is also bundled, but no
  dictionaries ship with it: a user who wants hunspell drops their own `en_US.aff`/`.dic` into
  `~/.config/enchant/hunspell/` (§13). *Rationale: the root-cause fix for the en_US crash is
  `AppleSpell.config`, not a dict; applespell covers the default path, so vendoring a ~50k-line
  word list (license tracking, repo/diff bloat) buys little. Hunspell stays a documented BYO option.*
- **D — Provenance: pixi/conda dependency, pinned by `pixi.lock`.** Reuse misemacs's
  existing reproducibility contract; adding the companion stays a **data change**
  (`pixi.toml` row). Rejected: standalone artifact fetch (second locking mechanism);
  inline `rattler-build` (toolchain weight + recipe co-ownership).
- **E — Layout: self-contained sub-prefix, NOT flattened into `Frameworks`.** Forced by
  the feedstock's self-relocation (§5.1): libenchant must keep a `…/lib/libenchant-2.2.dylib`
  + `…/lib/enchant-2/*.so` structure. See §7.
- **F — Treat the feedstock as a *relocatable unit*** rather than re-deriving its layout.
  enchant's closure (glib, hunspell, …) is **largely disjoint** from Emacs's own closure,
  so isolating it under the sub-prefix is cheap: any overlap is limited to a few low-level
  libs (e.g. `libintl`/`libiconv`) that may appear in both `Frameworks` and `enchant/lib`
  — a harmless few-hundred-KB duplication, not a maintenance hazard.
- **G — Generality: build the seam, not the framework.** One `Orchestrator.Payload`
  behaviour (`stage → relocate → verify`) with a single `Orchestrator.Payload.Enchant`
  implementation. No `payloads.toml` DSL until a second real payload exists.

## 5. Verified upstream facts (the constraints that shaped this)

### 5.1 Feedstock (`djgoku/enchant-feedstock@misemacs-recipe`, `recipe/recipe.yaml`)
- enchant **2.8.2**; `--disable-static --enable-relocatable --disable-vala --with-applespell`.
- Providers installed at `lib/enchant-2/enchant_hunspell.so`,
  `lib/enchant-2/enchant_applespell.so` (note: `enchant_*.so`, not `libenchant_*.so`).
- **Self-relocation** = a C constructor appended to `lib/api.c` that uses `dladdr()` to
  find libenchant at load time, **strips `/libenchant-2.2.dylib` then `/lib`**, and calls
  `enchant_set_prefix_dir(<that dir>)`. ⇒ **Hard constraint:** libenchant at
  `<P>/lib/libenchant-2.2.dylib`, providers at `<P>/lib/enchant-2/`. The `/lib/`
  component is load-bearing.
- Host/run deps: **glib + hunspell**. Closure ≈ libenchant + libglib-2.0 (+ gobject,
  gthread, intl, pcre2, ffi as applicable) + libhunspell.
- Headers + `enchant-2.pc` installed by standard autotools `make install`.

### 5.2 jinx (`minad/jinx`, `jinx.el`)
- **No** `jinx-c-flags`/`jinx-libs`. Compiles with hardcoded `jinx--compile-flags`
  (`-I. -O2 -Wall -Wextra -fPIC -shared`) **plus** `pkg-config --cflags --libs enchant-2`.
- Missing pkg-config ⇒ falls back to `/usr/include/enchant-2 … /usr/local/lib -lenchant-2`
  (wrong for a bundle). So integration = **make `pkg-config enchant-2` resolve to the
  bundle, scoped to jinx's compile**.
- **Recompiles only if the `.so` is absent** (existence check, no timestamp).
- Needs a real `cc` (Xcode Command Line Tools) on the user machine regardless — jinx
  cannot work without a toolchain, bundle or no bundle. "Clean machine" for jinx therefore
  means "clean **except CLT**". (Documented limitation, not solvable by us.)

## 6. Provenance & pinning

Add to **each** `versions/<name>/pixi.toml` (`master`, `emacs-31`) — **git-source via pixi-build**
(Phase 0 resolution, §2), not a published channel:
```toml
[workspace]
preview = ["pixi-build"]

[dependencies]
enchant = { git = "https://github.com/djgoku/enchant-feedstock", branch = "misemacs-recipe", subdirectory = "recipe" }
```
Re-lock both `pixi.lock`s (`pixi.lock` pins the resolved git commit — the single pin, no second
mechanism). enchant sits **inert** in the build env — Emacs never links it (no configure flag
change); the pipeline copies it out of `$CONDA_PREFIX` at stage time (§8).

`pixi.lock` is the single pin. No second mechanism.

## 7. Bundle layout

enchant is staged as a **self-contained sub-prefix** under `Contents/Resources/enchant/`,
mirroring its conda prefix so the §5.1 self-relocation resolves providers correctly:

```
Emacs.app/Contents/
├── Resources/
│   ├── enchant/                                  # self-contained enchant sub-prefix
│   │   ├── lib/
│   │   │   ├── libenchant-2.2.dylib              # id → @rpath/libenchant-2.2.dylib
│   │   │   ├── libglib-2.0.0.dylib, libhunspell-*.dylib, …   # enchant's private closure
│   │   │   └── enchant-2/
│   │   │       ├── enchant_hunspell.so
│   │   │       └── enchant_applespell.so
│   │   ├── include/enchant-2/enchant.h (+ enchant++.h)
│   │   ├── lib/pkgconfig/enchant-2.pc            # rewritten ${pcfiledir}-relative
│   │   ├── share/enchant-2/
│   │   │   ├── enchant.ordering                  # *:applespell,hunspell (§13)
│   │   │   └── AppleSpell.config                 # applespell locale map (staged from prefix; §13)
│   │   │                                          # NOTE: no share/hunspell/ — hunspell is BYO (§13)
│   │   └── bin/
│   │       ├── enchant-2 (+ enchant-lsmod-2)     # CLIs; on PATH via registry files: (§12)
│   │       └── pkg-config                        # jinx shim (self-locating shell script, §10)
│   └── site-lisp/site-start.el                   # jinx discovery + self-heal shim (§11)
```

Rationale: the whole enchant closure lives under `enchant/lib/` with `@loader_path`-relative
rpaths *within that dir*, so libenchant, its providers, glib, and hunspell resolve each
other internally, and `dladdr()` self-relocation finds providers at `enchant/lib/enchant-2/`.
Nothing enchant-related goes into `Contents/Frameworks` (that stays Emacs's closure).

> **O1 — RESOLVED (2026-06-28, real build):** the `--with-ns` app auto-loads
> `Contents/Resources/site-lisp/` — verified against the built master Emacs.app:
> `site-run-file = site-start` and that dir is on `load-path` (alongside Emacs's own
> `subdirs.el`). `stage_copy` writes `site-start.el` there; no change needed.

## 8. Staging & relocation mechanism (the seam)

New module `Orchestrator.Payload.Enchant` implementing an `Orchestrator.Payload`
behaviour: `stage/2`, `relocate/1`, `verify/1`. Driven by a `mix payload.enchant` task +
thin `pipeline/stage-enchant` wrapper, invoked **after build, before the deep sign**.

**`stage(app, conda_prefix)`** — pure-ish copy + normalize:
1. Copy enchant's closure from `$CONDA_PREFIX/lib` into `enchant/lib/` — `libenchant-2.2.dylib`,
   `lib/enchant-2/enchant_*.so`, and the transitive **foreign** closure of each (glib,
   hunspell, …) resolved with the *same* `Orchestrator.Macho` primitives the Emacs relocator
   uses, but with **bundle root = `enchant/lib/`** instead of `Contents/Frameworks`. **Also
   stage the unversioned `libenchant-2.dylib` symlink** alongside `libenchant-2.2.dylib` —
   jinx's `cc … -lenchant-2` link step needs it; staging only the versioned dylib fails with
   *library 'enchant-2' not found* (spike-A).
2. Copy `include/enchant-2/*.h`, `lib/pkgconfig/enchant-2.pc`, `bin/enchant-2`.
3. Set ids on staged dylibs → `@rpath/<base>`; the providers and CLI get a depth-correct
   `@loader_path` rpath into `enchant/lib/` (CLI is at `enchant/bin`, rpath
   `@loader_path/../lib`; providers at `enchant/lib/enchant-2`, rpath `@loader_path/..`).
4. Rewrite `enchant-2.pc` `prefix=` → `${pcfiledir}`-relative (§10).
5. Drop the `pkg-config` shim (§10) and `site-start.el` (§11).

**Relocator integration** (minimal, well-bounded change to `Relocate.run/3`):
- `machos/2` **excludes `Contents/Resources/enchant/**`** — the payload owns relocating its
  own subtree; the Emacs relocator must not flatten enchant's closure into `Frameworks`.
- `Relocate.run` calls `Payload.Enchant.relocate(app)` (install_name/rpath edits) **before**
  `tool.sign_bundle(app)`. **Spike-validated (2026-06-25): `codesign --deep` does NOT
  re-sign Mach-Os under `Contents/Resources/` — it skips them, and the app-level
  `--deep --strict` *verify* skips them too.** They still *load* (the toolchain leaves a
  valid ad-hoc linker-signature that modern `install_name_tool` re-applies after edits), but
  we must not rely on that surviving every edit. So `Payload.Enchant.relocate` **signs and
  verifies each enchant Mach-O explicitly** (`codesign --force --sign -` per file, then
  `codesign --verify --strict`) before the app deep-sign runs over the rest.
- After verify, run **both** gates: the existing Emacs `gate(app, fw)` (enchant excluded)
  **and** `Payload.Enchant.verify(app)` (otool self-containment over `enchant/**` +
  functional `enchant-2 -list-dicts`, §14).

This is the only change to the otherwise-generic relocator: a single, explicitly-justified
"payloads are self-contained, skip them" exclusion.

## 9. The `.pc` rewrite

`enchant-2.pc` ships with `prefix=/…conda…`. Rewrite to be bundle-relative so a real
`pkg-config` (if the user has one) resolves correctly:
```
prefix=${pcfiledir}/../..        # pcfiledir = …/enchant/lib/pkgconfig → prefix = …/enchant
libdir=${prefix}/lib
includedir=${prefix}/include
…
Libs: -L${libdir} -lenchant-2 -Wl,-rpath,${libdir}
```
Note `-Wl,-rpath,${libdir}` is injected into `Libs:` so a module linked via this `.pc`
finds libenchant at runtime.

## 10. jinx `pkg-config` shim

Because jinx shells out to `pkg-config enchant-2` and a clean (CLT-only) machine has **no
pkg-config**, ship a tiny self-locating shim at `enchant/bin/pkg-config`:
```sh
#!/bin/sh
# minimal pkg-config shim: answers enchant-2 for jinx's `--cflags --libs` call
prefix=$(cd "$(dirname "$0")/.." && pwd)        # → …/Contents/Resources/enchant
echo "-I$prefix/include/enchant-2 -L$prefix/lib -lenchant-2 -Wl,-rpath,$prefix/lib"
```
It is **scoped to jinx's compile only** (via the §11 advice prepending `enchant/bin` to
`exec-path`), so it never shadows a real system `pkg-config` for other code.

> **O2 — RESOLVED (2026-06-28): the shim is chosen** (not bundling real `pkgconf`). It is minimal,
> fully controls output (incl. `-Wl,-rpath`), **refuses non-`enchant-2` queries** (exits non-zero),
> and is `exec-path`-scoped to jinx's compile by §11 — so it never shadows a real system
> `pkg-config`. The real `${pcfiledir}`-relative `.pc` (§9) still ships for non-jinx consumers.

## 11. The Emacs-Lisp shim (`site-start.el`)

Self-locating, **discovery-only** (no policy — does not enable jinx, does not touch
`ispell-program-name`). Fires only if/when jinx loads:

```elisp
;; misemacs: point jinx's compile at the bundled enchant. Discovery only — no global env.
(let* ((app  (expand-file-name "../../.." (file-name-directory load-file-name)))
       (ench (expand-file-name "Contents/Resources/enchant" app))
       (bin  (expand-file-name "bin" ench)))
  ;; scope our pkg-config shim to jinx's module compile only:
  (with-eval-after-load 'jinx
    (when (fboundp 'jinx--load-module)              ; O4: guard before advising
      (advice-add 'jinx--load-module :around
        (lambda (orig &rest args)
          (let ((exec-path (cons bin exec-path)))
            (apply orig args)))))))
```

**Stale-module handling — spike-validated (2026-06-25).** The compiled `jinx-mod.so` lives
in the user's elpa dir and embeds an absolute `LC_RPATH` to *this* dated app's `enchant/lib`;
jinx recompiles only when the `.so` is **absent** (§5.2). On an Emacs update the app path
changes and that rpath goes stale.

The spike **refuted the original DYLD self-heal**: mid-process `setenv "DYLD_FALLBACK_LIBRARY_PATH"`
from `site-start.el` does **not** reach a later `dlopen` (dyld snapshots the env at launch).
What worked:
- **Embedded `@rpath` (primary).** A module built with `-Wl,-rpath,<enchant/lib>` (what the
  §10 shim emits) resolves libenchant with no env at all — *while the path is current*.
- **On staleness the shim rpath-patches the module in place — chosen, spike-validated:**
  `install_name_tool -rpath <old> <current> jinx-mod.so` rewrites the embedded rpath and
  (arm64) re-signs automatically; the patched module then `dlopen`s with **no recompile, no
  `cc`, no env**. Staleness is detected by comparing the module's embedded rpath (`otool -l`)
  to the current `enchant/lib`. **Fallback** if a patch ever fails: delete-to-recompile
  (remove the stale `.so`; jinx rebuilds it). A launch-time env wrapper also works but is more
  invasive and reintroduces DYLD fragility under a future hardened runtime — **not** chosen.

> **Open items / review questions:**
> - **O3 (spike-resolved):** DYLD `setenv` self-heal is dead; staleness is fixed by an
>   in-place `install_name_tool -rpath` patch (recompile-free, auto re-signed), with
>   delete-to-recompile as the fallback.
> - **O4 (folded in):** advice is now guarded by `fboundp 'jinx--load-module`; still record
>   the jinx version tested and re-confirm name/arity against the pin.
> - **O5 — RESOLVED (2026-06-28): keep auto-load, discovery-only.** `site-start.el` no longer
>   mutates global env (DYLD removed); its only effect is adding `with-eval-after-load 'jinx`
>   advice — benign if jinx is absent, and `-Q` / `--no-site-file` bypasses it. An explicit
>   opt-out var **is** shipped: `(setq misemacs-enchant-disable t)`. (Note: hunspell-dict
>   discovery deliberately does NOT auto-set `XDG_DATA_DIRS` — same no-global-env principle, §13.)

## 12. PATH exposure

Expose the CLI like `Emacs`/`emacsclient`: add a `files:` entry
(`src: "{{.AssetWithoutExt}}/Emacs.app/Contents/Resources/enchant/bin/enchant-2"`) to
**both** packages in `aqua/registry.yaml`, and add `enchant-2` to the bin list emitted by
`mix release.names` so `pipeline/package`'s layout check + self-verify cover it.
(`registry.yaml` is slated to be generated from `versions.toml` in a later phase; until
then it is hand-edited — two entries.)

## 13. Backend / provider configuration

- **applespell is the default** ordering for all languages; hunspell is the dictionary-less
  fallback. Ship a one-line ordering config **`*:applespell,hunspell`** to make applespell
  the default backend.
- **Ordering path — spike-resolved (O8):** enchant 2.8 reads global ordering from
  `etc/enchant-2/enchant.ordering` (config) and `share/enchant-2/enchant.ordering` (data) —
  **NOT** `share/enchant/`. Ship it at **`enchant/share/enchant-2/enchant.ordering`**.
  `ENCHANT_CONFIG_DIR` / `~/.config/enchant` can override at runtime but affect *ordering
  only*, not provider-module lookup — so the §5.1 `dladdr` self-relocation is the sole
  mechanism that finds providers (no env shortcut exists).
- **`AppleSpell.config` is required (root-cause finding, 2026-06-28).** The feedstock ships
  `share/enchant-2/AppleSpell.config` (the applespell locale map, e.g. `en_US⇥en⇥English`).
  `stage_copy` **must** copy it from the conda prefix. Without it applespell claims no locale,
  `enchant_broker_dict_exists("en_US")` returns 0, and enchant falls back to the bare-language
  tag `en`, which triggers a **flaky upstream applespell NULL-deref** (`enchant_dict_finalize(NULL)`
  ← `enchant_broker_new_dict` ← `appleSpell_provider_request_dict(tag="en")`). With it staged,
  `dict_exists("en_US")=1`, applespell checks + suggests correctly, and `enchant-2 -l -d en_US`
  no longer crashes (verified cleanroom, real artifact). *Residual:* the bare-`en` upstream crash
  remains latent (only reachable if a caller explicitly requests `en` with no region) — recommend
  a feedstock patch to `applespell_checker.mm` as a follow-up; region tags (en_US/en_GB/…) are safe.
- **Hunspell dictionaries — bring-your-own (none bundled).** The hunspell provider ships, but no
  dictionaries do. applespell is the default and needs no dict files, so the common path requires
  nothing extra. A user who wants hunspell drops their own `en_US.aff`/`.dic` (e.g. from the
  LibreOffice dictionaries repo or `app.aspell.net/create`) into `~/.config/enchant/hunspell/` —
  the per-user dir the provider searches (`g_get_system_data_dirs()/hunspell` +
  `~/.config/enchant/hunspell`; **not** the enchant prefix, since dladdr relocation does not reach
  dict lookup, so no env var is needed for the per-user path). *We deliberately do not vendor a
  word list:* applespell covers the default, and a ~50k-line `.dic` adds license-tracking and
  repo/diff bloat for the secondary path. Activation (files + an `enchant.ordering` preferring
  hunspell) is documented in the README.

> **O6 — RESOLVED (2026-06-28):** applespell checking *and* suggestions work for `en_US`/`en_GB`
> once `AppleSpell.config` is staged (e.g. `helllo → hello, he'll`). No hunspell dictionary is
> bundled — hunspell is a documented bring-your-own option (above).

## 14. Testing / validation (Definition of Done)

Extend the existing gates rather than inventing a parallel harness:
- **Relocation gates (build host):** Emacs `macho_gate` PASS (enchant excluded) **and**
  `Payload.Enchant.verify` PASS — otool self-containment over `enchant/**` (no foreign
  deps/rpaths; every `@rpath/<base>` resolvable within `enchant/lib`) **plus a per-file
  `codesign --verify --strict` on every enchant Mach-O** (the app-level `--deep` verify
  skips `Resources/` — §8, spike-validated).
- **Functional smoke (build host):** `…/enchant/bin/enchant-lsmod-2` lists the applespell +
  hunspell providers (spike-A: `enchant-2 -list-dicts` is **not** valid — `enchant-2`'s flags
  are `-a|-l|-h|-v`; `enchant-lsmod-2` is the module/provider lister).
- **Build-prefix leak gate — DROPPED (2026-06-28).** The original `strings | grep <conda
  prefix>` check (over every enchant Mach-O) was **too strict**: real conda dylibs (libenchant,
  the providers, glib/gio/intl) bake the install prefix into **inert data-section strings** that
  `install_name_tool` cannot strip, so the gate false-flagged 6 legitimately-relocated libs. The
  self-containment that matters is in the **load commands** (proven by the macho gate) and is
  confirmed functionally by the cleanroom run; `dladdr` self-relocation overrides any compiled-in
  prefix at runtime. `verify/3` therefore runs only the otool gate + per-file codesign verify.
  (The generated `.pc` is `${pcfiledir}`-relative and carries no prefix by construction.)
- **Cleanroom (pregate macOS VM) — extend `mise run cleanroom`:** with the pixi env moved
  aside (proving no build-env leakage), run:
  1. `enchant-lsmod-2` resolves providers from the bundle alone.
  2. A jinx end-to-end: `package-install jinx`, force module compile, spell-check a known
     word — proving headers + shim `pkg-config` + link + runtime libenchant resolution all
     work with no Homebrew/system enchant. (Requires CLT in the VM — see §5.2.)
  3. **Symlinked-launch test (spike-D / O9):** invoke the app **through a symlink** (mise/aqua
     installs can symlink) and re-run (1) — confirms `dladdr` resolves providers under
     symlinked access, not just direct paths.
- **Package self-verify:** `enchant-2` present + executable in the tarball (via the
  release.names bin list).

## 15. Risks & open questions (consolidated for review)

| # | Item | Where |
|---|------|-------|
| S1 | ✅ spike-resolved: `codesign --deep` skips `Resources/` → payload self-signs each Mach-O | §8 |
| O1 | Exact `site-lisp` path in the `--with-ns` install tree | §7 |
| O2 | Fake `pkg-config` shim vs. bundling real `pkgconf` | §10 |
| O3 | ✅ spike-resolved: DYLD self-heal dead; staleness fixed by in-place rpath-patch | §11 |
| O4 | ⚙ folded: advice guarded by `fboundp`; still confirm name/arity vs. pin | §11 |
| O5 | `site-start.el` opt-out? (no longer mutates global env) | §11 |
| O6 | ✅ resolved (2026-06-28): applespell checks+suggests `en_US` once `AppleSpell.config` staged; hunspell is bring-your-own (no bundled dict) | §13 |
| O7 | ✅ resolved: Phase 0 = **git-source via pixi-build** (no channel publish/credentials) | §2, §6 |
| O8 | ✅ spike-resolved: ordering at `share/enchant-2/` (or `etc/enchant-2/`), not `share/enchant/` | §13 |
| O9 | ✅ resolved (2026-06-28, real build + cleanroom): `enchant-lsmod-2` + `enchant-2 -d en_US` resolve providers through an absolute symlink to the app — `dladdr` handles symlinked launch | §14 |
| O1 | ✅ resolved (2026-06-28, real build): site-lisp = `Contents/Resources/site-lisp/`, `site-run-file=site-start` | §7 |
| O2 | ✅ resolved: pkg-config **shim** chosen (refuses non-enchant-2; exec-path-scoped) | §10 |
| O5 | ✅ resolved: `site-start.el` auto-loads, discovery-only, opt-out `misemacs-enchant-disable` | §11 |
| O10 | ✅ root-caused (2026-06-28): en_US SEGFAULT + `dict_exists=0` = **missing `AppleSpell.config`** (not dict-less hunspell); fixed by staging it. Residual upstream applespell bare-`en` crash → feedstock-patch follow-up | §13 |
| O11 | ✅ resolved: build-prefix `leak_check` **dropped** (real dylibs bake inert prefix strings → false positives) | §14 |
| A | ✅ spike-validated: `.pc` rewrite + shim → jinx compiles/links/loads vs. a relocated bundle; needs unversioned symlink | §8–§10 |
| B | ✅ validated (2026-06-28): git-source feedstock build ships both provider `.so`s + dladdr; staged + cleanroom-verified | §8, §2 |

## 16. Implementation outline (for the plan, not this spec)

1. **Phase 0 (feedstock, external):** build + publish enchant 2.8.2 to the channel.
2. Add `enchant` to both `pixi.toml`s + re-lock (Decision D).
3. `Orchestrator.Payload` behaviour + `Orchestrator.Payload.Enchant` (stage/relocate/verify),
   reusing `Orchestrator.Macho` with bundle-root = `enchant/lib`.
4. Relocator change: exclude `enchant/**` from `machos/2`; `Payload.Enchant.relocate`
   self-signs + verifies each enchant Mach-O (§8, spike-validated); then the app deep-sign;
   run both gates.
5. `.pc` rewrite + `pkg-config` shim + `site-start.el` (§9–§11).
6. Registry `files:` + `release.names` bin entry (§12).
7. Extend `cleanroom` with the enchant + jinx smoke (§14).
8. Resolve O1–O8.
