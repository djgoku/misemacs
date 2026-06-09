# Phase 2 — Build + Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, relocatable **GUI** `Emacs.app` from the per-version pixi env that launches on a clean macOS arm64 machine with no pixi/conda/Homebrew present.

**Architecture:** Two bash pipeline stages — `pipeline/build-emacs` (configure+make+install against the locked pixi env) and `pipeline/bundle-relocate` (a generic Mach-O closure walk that copies every non-system dylib into `Contents/Frameworks`, fixes install-names/rpaths to be bundle-relative, and ad-hoc re-signs) — plus a shared, fixture-tested helper library `lib/macho.sh` that includes the self-contained **gate**. Proof of done: the static `macho_gate` is green AND the relocated app runs `--batch` (+ a GUI frame smoke) inside a fresh tart VM that never had pixi.

**Tech Stack:** bash, `otool`/`install_name_tool`/`codesign` (Xcode CLT), pixi (locked build env), mise (tasks + toolchain), tart 2.31.0 (clean-room VM), clang (test fixtures).

---

## Decisions frozen here (the 2026-06-09 brainstorm outcome)

These were settled with the user during brainstorming; the umbrella spec (`docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`) is reconciled to match in Task 7.

- **GUI-only.** v1 deliverable is the NS `Emacs.app`. The GUI never initializes terminfo, so `bundle-relocate` is a **pure generic Mach-O walk with zero special-cases** — ncurses is bundled like any other dylib (its dylib only needs to *resolve* at load).
- **`emacs -nw` is out of scope** and recorded in spec §15 as a **post-Phase-4 fast-follow** (one-row system-rewrite of `libncurses` → `/usr/lib/libncurses.5.4.dylib`). Validated 2026-06-09: a *bundled* conda ncurses 6.6 searches only `$CONDA_PREFIX/share/terminfo` (`infocmp -D`), so `-nw` would need that rewrite or a `TERMINFO_DIRS` launcher. **Do not** add terminfo handling in Phase 2.
- **Decision C — minimal ad-hoc re-sign lives in Phase 2.** `install_name_tool` invalidates code signatures and arm64 kills an invalid-sig binary, so `bundle-relocate` ad-hoc re-signs (`codesign -s - -f`) every Mach-O it rewrites. Proper/deep/Developer-ID signing remains Phase 3.
- **Decision D — `bin/` move + Info.plist/icon stay in Phase 4.** Phase 2 relocates whatever Mach-O `make install` produces, in their default locations.
- **Decision E — the host `make`/CLT fingerprint gap (spec §8): record now, wire in Phase 5.** Resolution recorded in Task 7: fold `xcode-select -p` + the active clang/SDK build version into `toolchain_hash` when the fingerprint is consumed (Phase 5). No code in Phase 2.
- **rpath ownership.** `build-emacs` adds only `-Wl,-headerpad_max_install_names` and `-Wl,-rpath,$CONDA_PREFIX/lib` (the latter solely so the in-build dump step can load conda dylibs — Phase-1 finding). `bundle-relocate` adds the depth-correct `@loader_path/<rel-to-Frameworks>` rpath to every Mach-O and deletes the `$CONDA_PREFIX/lib` rpath. (Refines spec §9, which sketched `@executable_path/../Frameworks` and omitted the build-time conda rpath.)
- **Clean-VM proof is host-side.** `mise run cleanroom` clones a fresh tart VM (no pixi) and launches the relocated app. pregate (itself a VM; no nested virt) runs build + relocate + the static `macho_gate` instead.

## File Structure

| Path | New? | Responsibility |
|---|---|---|
| `lib/macho.sh` | create | Sourced helpers over `otool`/`install_name_tool`/`codesign` + `macho_gate` (the self-contained check). Pure host tools, no pixi. |
| `tests/macho_test.sh` | create | Unit tests for `lib/macho.sh` using tiny clang fixtures (fast, no Emacs build). |
| `pipeline/bundle-relocate` | create | The crux: generic Mach-O closure walk → `Contents/Frameworks`, rpath/install-name fixes, re-sign, ends with `macho_gate`. |
| `tests/bundle-relocate_test.sh` | create | Integration test of `bundle-relocate` against a synthetic 2-level conda-style bundle; proves it runs with the build libdir moved aside (clean-machine proxy). |
| `pipeline/build-emacs` | create | Fetch + configure + make + install under the pixi env → `build/<v>/Emacs.app` + `conda-prefix-lib.txt` + an otool discovery dump. |
| `scripts/cleanroom.sh` | create | Host-side tart-VM DoD proof: copy the relocated app into a fresh no-pixi VM and run `--batch` + a GUI frame smoke. |
| `mise.toml` | modify | Add tasks `build`, `relocate`, `test-macho`, `cleanroom`. |
| `.gitignore` | modify | Ignore `/build/` (the ephemeral build/relocate output). |
| `.pregate/macos.sh` | modify | After the shared body: `test-macho` + `build` + `relocate` (static gate). No nested VM. |
| `versions/master/mise.toml` | modify | Fix the now-stale "ncurses = system /usr/lib" comment (Task 7). |
| `docs/superpowers/validation-log.md` | modify | Phase 2 findings + decision E (Task 7). |
| `docs/superpowers/specs/2026-06-05-…-design.md` | modify | Reconcile §6.2/§8/§9/§13 (Task 7). |

**Conventions to follow (from Phase 0/1):** stages are standalone bash invoked as `bash pipeline/<stage> <version>`; they read `EMACS_REF`/`EMACS_CONFIGURE_FLAGS` from `versions/<v>/mise.toml` via `mise exec`; the pixi env is entered with `mise exec -- pixi run --manifest-path "$VDIR/pixi.toml"` (the validated direct-pixi path from `scripts/configure-check.sh`). Commit after each task.

## Branch setup (already done)

Work happens on the existing worktree branch `claude/modest-payne-854333` (worktree root `/Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/modest-payne-854333`). All paths below are relative to that root. Do **not** push or rebase (the user owns those).

---

## Task 1: `lib/macho.sh` — Mach-O helpers + the self-contained gate (TDD)

**Files:**
- Create: `lib/macho.sh`
- Test: `tests/macho_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/macho_test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for lib/macho.sh — tiny clang fixtures (fast; no Emacs build).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/lib/macho.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2' want '$3')"; }

# fixtures: 'conda-style' dylibs with @rpath ids in a build libdir; an app exe with a foreign rpath.
mkdir -p "$T/buildlib" "$T/App.app/Contents/MacOS" "$T/App.app/Contents/Frameworks"
printf 'int bar(void){return 5;}\n' > "$T/bar.c"
clang -dynamiclib -install_name '@rpath/libbar.dylib' -Wl,-headerpad_max_install_names \
      "$T/bar.c" -o "$T/buildlib/libbar.dylib"
printf 'int bar(void); int foo(void){return bar()+2;}\n' > "$T/foo.c"
clang -dynamiclib -install_name '@rpath/libfoo.dylib' -Wl,-headerpad_max_install_names \
      -L"$T/buildlib" -lbar -Wl,-rpath,"$T/buildlib" "$T/foo.c" -o "$T/buildlib/libfoo.dylib"
printf 'int foo(void); int main(void){return foo()-7;}\n' > "$T/main.c"
EXE="$T/App.app/Contents/MacOS/App"
clang -Wl,-headerpad_max_install_names -L"$T/buildlib" -lfoo -Wl,-rpath,"$T/buildlib" \
      "$T/main.c" -o "$EXE"

# 1. is_macho
macho_is_macho "$EXE"      && ok "is_macho exe"            || bad "is_macho exe"
macho_is_macho "$T/main.c" && bad "is_macho rejects src"   || ok "is_macho rejects src"

# 2. class
eq "class system"  "$(macho_class /usr/lib/libSystem.B.dylib)" system
eq "class bundled" "$(macho_class @rpath/libfoo.dylib)"        bundled
eq "class foreign" "$(macho_class "$T/buildlib/libfoo.dylib")" foreign

# 3. deps lists @rpath dep, excludes the dylib's own id
macho_deps "$T/buildlib/libfoo.dylib" | grep -qx '@rpath/libbar.dylib' && ok "deps libbar" || bad "deps libbar"
macho_deps "$T/buildlib/libfoo.dylib" | grep -qx '@rpath/libfoo.dylib' && bad "deps exclude self" || ok "deps exclude self"

# 4. rpaths
macho_rpaths "$EXE" | grep -qx "$T/buildlib" && ok "rpath present" || bad "rpath present"

# 5. relpath
eq "relpath MacOS->FW" "$(macho_relpath "$T/App.app/Contents/Frameworks" "$T/App.app/Contents/MacOS")" "../Frameworks"
eq "relpath FW->FW"    "$(macho_relpath "$T/App.app/Contents/Frameworks" "$T/App.app/Contents/Frameworks")" "."

# 6. gate FAILS before relocation (foreign rpath; @rpath deps not in Frameworks)
if macho_gate "$T/App.app" >/dev/null 2>&1; then bad "gate should fail pre-reloc"; else ok "gate fails pre-reloc"; fi

echo "macho_test: $pass passed, $fail failed"; [ "$fail" = 0 ]
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/macho_test.sh`
Expected: FAIL — `lib/macho.sh` does not exist (`. "$HERE/lib/macho.sh": No such file or directory`).

- [ ] **Step 3: Write `lib/macho.sh`**

```bash
#!/usr/bin/env bash
# lib/macho.sh — Mach-O relocation helpers + the self-contained gate.
# Sourced by pipeline/bundle-relocate and tests/macho_test.sh.
# Host tools only (otool/install_name_tool/codesign from Xcode CLT) — NO pixi/conda.

# True if $1 is a Mach-O file.
macho_is_macho() { [ -f "$1" ] && file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

# The install-name id of a dylib (empty for a plain executable).
macho_id() { otool -D "$1" 2>/dev/null | awk 'NR==2{print}'; }

# All linked dylib install-names of $1, excluding the file's own id.
macho_deps() {
  local self; self="$(macho_id "$1")"
  if [ -n "$self" ]; then
    otool -L "$1" 2>/dev/null | awk 'NR>1{print $1}' | grep -vxF "$self" || true
  else
    otool -L "$1" 2>/dev/null | awk 'NR>1{print $1}'
  fi
}

# LC_RPATH entries of $1.
macho_rpaths() {
  otool -l "$1" 2>/dev/null | awk '/^ *cmd LC_RPATH$/{r=1;next} r&&/^ *path /{print $2;r=0}'
}

# Classify a path:
#   system  → /usr/lib/* or /System/*                          (leave as-is)
#   bundled → @rpath/* @executable_path/* @loader_path/*       (already bundle-relative)
#   foreign → any other absolute path                          (build-tree/conda/homebrew → must fix)
macho_class() {
  case "$1" in
    /usr/lib/*|/System/*) echo system ;;
    @rpath/*|@executable_path/*|@loader_path/*) echo bundled ;;
    /*) echo foreign ;;
    *) echo other ;;
  esac
}

# Relative path to reach absolute dir $1 from absolute dir $2 (e.g. ../Frameworks, ../../Frameworks, .).
macho_relpath() {
  awk -v t="$1" -v f="$2" 'BEGIN{
    nt=split(t,T,"/"); nf=split(f,F,"/"); i=1;
    while (i<=nt && i<=nf && T[i]==F[i]) i++;
    up=""; for (j=i;j<=nf;j++) up=up "../";
    down=""; for (j=i;j<=nt;j++) down=down T[j] (j<nt?"/":"");
    r=up down; sub(/\/$/,"",r); if (r=="") r="."; print r;
  }'
}

# --- mutators (thin install_name_tool / codesign wrappers) ---
macho_set_id()       { install_name_tool -id "$2" "$1"; }
macho_change()       { install_name_tool -change "$2" "$3" "$1"; }
macho_add_rpath()    { install_name_tool -add_rpath "$2" "$1" 2>/dev/null || true; }   # idempotent: dup rpath is harmless
macho_delete_rpath() { install_name_tool -delete_rpath "$2" "$1" 2>/dev/null || true; }
macho_resign()       { codesign --remove-signature "$1" 2>/dev/null || true; codesign -s - -f "$1"; }  # ad-hoc (Decision C)

# macho_gate <bundle_root>: assert self-contained. Prints offenders; non-zero on any violation.
#   (1) no foreign dependency paths   (2) no foreign LC_RPATHs
#   (3) every @rpath/<lib> dependency exists under <root>/Contents/Frameworks
macho_gate() {
  local root="$1" fw="$1/Contents/Frameworks" rc=0 f dep rp base
  while IFS= read -r f; do
    macho_is_macho "$f" || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$(macho_class "$dep")" in
        foreign) echo "FOREIGN dep   $f -> $dep"; rc=1 ;;
        bundled) case "$dep" in
                   @rpath/*) base="${dep#@rpath/}"
                     [ -e "$fw/$base" ] || { echo "MISSING lib   $f -> $dep"; rc=1; } ;;
                 esac ;;
      esac
    done < <(macho_deps "$f")
    while IFS= read -r rp; do
      [ -n "$rp" ] || continue
      [ "$(macho_class "$rp")" = foreign ] && { echo "FOREIGN rpath $f -> $rp"; rc=1; }
    done < <(macho_rpaths "$f")
  done < <(find "$root" -type f)
  [ "$rc" = 0 ] && echo "macho_gate: PASS ($root self-contained)" || echo "macho_gate: FAIL ($root)"
  return $rc
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/macho_test.sh`
Expected: PASS — final line `macho_test: 11 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/macho.sh tests/macho_test.sh
git commit -m "feat(phase2): lib/macho.sh — Mach-O relocation helpers + self-contained gate"
```

---

## Task 2: `pipeline/bundle-relocate` — the generic relocation walk (TDD)

**Files:**
- Create: `pipeline/bundle-relocate`
- Test: `tests/bundle-relocate_test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/bundle-relocate_test.sh`:

```bash
#!/usr/bin/env bash
# Integration test: relocate a synthetic 2-level conda-style bundle, then prove it runs with the
# build libdir MOVED ASIDE (clean-machine proxy) and that macho_gate passes. Fast — no Emacs build.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/lib/macho.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
APP="$T/build/master/Emacs.app"
mkdir -p "$T/buildlib" "$APP/Contents/MacOS/bin"

# libbar <- libfoo <- {Emacs, bin/helper}, all @rpath via a build libdir.
printf 'int bar(void){return 5;}\n' > "$T/bar.c"
clang -dynamiclib -install_name '@rpath/libbar.dylib' -Wl,-headerpad_max_install_names \
      "$T/bar.c" -o "$T/buildlib/libbar.dylib"
printf 'int bar(void); int foo(void){return bar()+2;}\n' > "$T/foo.c"
clang -dynamiclib -install_name '@rpath/libfoo.dylib' -Wl,-headerpad_max_install_names \
      -L"$T/buildlib" -lbar -Wl,-rpath,"$T/buildlib" "$T/foo.c" -o "$T/buildlib/libfoo.dylib"
printf 'int foo(void); int main(void){return foo()-7;}\n' > "$T/main.c"
clang -Wl,-headerpad_max_install_names -L"$T/buildlib" -lfoo -Wl,-rpath,"$T/buildlib" \
      "$T/main.c" -o "$APP/Contents/MacOS/Emacs"
clang -Wl,-headerpad_max_install_names -L"$T/buildlib" -lfoo -Wl,-rpath,"$T/buildlib" \
      "$T/main.c" -o "$APP/Contents/MacOS/bin/helper"
printf '%s\n' "$T/buildlib" > "$T/build/master/conda-prefix-lib.txt"

# Run the stage with build root overridden to the fixture.
BUILD_ROOT="$T/build" bash "$HERE/pipeline/bundle-relocate" master

# Closure copied?
[ -e "$APP/Contents/Frameworks/libfoo.dylib" ] && [ -e "$APP/Contents/Frameworks/libbar.dylib" ] \
  || { echo "FAIL: closure not copied into Frameworks"; exit 1; }
# Gate green?
macho_gate "$APP"
# Clean-machine proxy: remove the build libdir, then both binaries must still run (rc 0 == foo()==7).
mv "$T/buildlib" "$T/buildlib.gone"
"$APP/Contents/MacOS/Emacs";      echo "  Emacs ran rc=$?"
"$APP/Contents/MacOS/bin/helper"; echo "  helper ran rc=$?"
echo "bundle-relocate_test: PASS"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/bundle-relocate_test.sh`
Expected: FAIL — `pipeline/bundle-relocate` does not exist (`No such file or directory`).

- [ ] **Step 3: Write `pipeline/bundle-relocate`**

```bash
#!/usr/bin/env bash
# pipeline/bundle-relocate <version> — make build/<version>/Emacs.app self-contained & relocatable.
# Generic over ALL Mach-O: bundle the non-system dylib closure into Contents/Frameworks, normalize
# refs to @rpath, give each Mach-O a depth-correct @loader_path rpath, delete the build-time conda
# rpath, ad-hoc re-sign (Decision C). NO ncurses/terminfo special-case (GUI-only — spec §15).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/lib/macho.sh"
VERSION="${1:-master}"
BUILD_ROOT="${BUILD_ROOT:-$HERE/build}"
APP="$BUILD_ROOT/$VERSION/Emacs.app"
BUILD_LIBDIR="$(cat "$BUILD_ROOT/$VERSION/conda-prefix-lib.txt")"
[ -d "$APP" ] || { echo "FATAL: $APP missing — run build-emacs first"; exit 1; }
FW="$APP/Contents/Frameworks"; mkdir -p "$FW"
APP="$(cd "$APP" && pwd)"; FW="$(cd "$FW" && pwd)"   # canonicalize for relpath

# Resolve a dependency to a real source file in the build env (or empty if not bundleable).
resolve_src() {
  case "$(macho_class "$1")" in
    foreign) printf '%s\n' "$1" ;;                                   # absolute build path → itself
    bundled) case "$1" in @rpath/*) printf '%s\n' "$BUILD_LIBDIR/${1#@rpath/}" ;; esac ;;
  esac
}
# Deps of $1 that need a copy into Frameworks (foreign-absolute, or @rpath/*).
bundleable_deps() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$(macho_class "$d")" in
      foreign) printf '%s\n' "$d" ;;
      bundled) case "$d" in @rpath/*) printf '%s\n' "$d" ;; esac ;;
    esac
  done < <(macho_deps "$1")
}

# 1. BFS the closure into Frameworks.
# NOTE: stock macOS bash is 3.2 — no associative arrays / array slicing. Use file-based worklist.
seen="$(mktemp)"; work="$(mktemp)"; trap 'rm -f "$seen" "$work"' EXIT
while IFS= read -r f; do macho_is_macho "$f" && bundleable_deps "$f"; done < <(find "$APP" -type f) >> "$work"
while [ -s "$work" ]; do
  dep="$(head -n1 "$work")"; sed -i '' '1d' "$work"   # pop queue head (BSD sed in-place)
  base="$(basename "$dep")"
  grep -qxF "$base" "$seen" && continue
  printf '%s\n' "$base" >> "$seen"
  src="$(resolve_src "$dep")"
  if [ -z "$src" ] || [ ! -e "$src" ]; then echo "WARN: cannot resolve $dep (src='$src')"; continue; fi
  cp -f "$src" "$FW/$base"; chmod u+w "$FW/$base"
  macho_set_id "$FW/$base" "@rpath/$base"
  bundleable_deps "$FW/$base" >> "$work"             # enqueue its deps (transitive closure)
done

# 2. Rewrite refs + rpaths + re-sign on every Mach-O in the bundle.
while IFS= read -r f; do
  macho_is_macho "$f" || continue
  # 2a. normalize any bundled foreign-absolute dep → @rpath/<base>
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if [ "$(macho_class "$dep")" = foreign ]; then
      b="$(basename "$dep")"; [ -e "$FW/$b" ] && macho_change "$f" "$dep" "@rpath/$b"
    fi
  done < <(macho_deps "$f")
  # 2b. add depth-correct @loader_path rpath to Frameworks; delete the build-time conda rpath(s)
  rel="$(macho_relpath "$FW" "$(cd "$(dirname "$f")" && pwd)")"
  macho_add_rpath "$f" "@loader_path/$rel"
  while IFS= read -r rp; do
    [ "$(macho_class "$rp")" = foreign ] && macho_delete_rpath "$f" "$rp"
  done < <(macho_rpaths "$f")
  # 2c. ad-hoc re-sign (Decision C — relocation invalidated the signature)
  macho_resign "$f"
done < <(find "$APP" -type f)

# 3. The gate.
macho_gate "$APP"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/bundle-relocate_test.sh`
Expected: PASS — `macho_gate: PASS`, `Emacs ran rc=0`, `helper ran rc=0`, final `bundle-relocate_test: PASS`.

- [ ] **Step 5: Commit**

```bash
git add pipeline/bundle-relocate tests/bundle-relocate_test.sh
git commit -m "feat(phase2): bundle-relocate — generic Mach-O closure walk + relocation"
```

---

## Task 3: `pipeline/build-emacs` — build the relocatable-candidate app

**Files:**
- Create: `pipeline/build-emacs`

This stage runs a real ~15–20 min build; it has no fast unit test. Its "test" is that it produces a runnable `Emacs.app` and the discovery dump (Step 2). Tasks 1–2 already proved the relocation logic on fixtures.

- [ ] **Step 1: Write `pipeline/build-emacs`**

```bash
#!/usr/bin/env bash
# pipeline/build-emacs <version> — build a relocatable-CANDIDATE GUI Emacs.app from the per-version
# pixi env. Output: build/<version>/Emacs.app (still linked to pixi @rpath libs) + conda-prefix-lib.txt
# + otool-prereloc.txt. bundle-relocate makes it self-contained. native-comp OFF; GUI-only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-master}"
VDIR="$HERE/versions/$VERSION"
OUT="$HERE/build/$VERSION"; SRC="$OUT/src"
PIXI=(mise exec -- pixi)
[ -f "$VDIR/pixi.toml" ] || { echo "FATAL: $VDIR/pixi.toml missing"; exit 1; }
EMACS_REF="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_REF:?}"')"
EMACS_FLAGS="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_CONFIGURE_FLAGS:?}"')"
mkdir -p "$OUT"
echo ">> [1] fetch emacsmirror/emacs $EMACS_REF -> $SRC"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "$EMACS_REF"; git -C "$SRC" checkout -q -f FETCH_HEAD
else
  rm -rf "$SRC"; git clone --depth 1 --branch "$EMACS_REF" https://github.com/emacsmirror/emacs "$SRC"
fi
echo ">> [2] configure + make + install UNDER the pixi env"
"${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" bash -euo pipefail -c '
  cd "'"$SRC"'"
  export PATH="$CONDA_PREFIX/bin:$PATH"
  export PKG_CONFIG="$CONDA_PREFIX/bin/pkg-config" PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig"
  ./autogen.sh
  # -headerpad_max_install_names: room for install_name rewrites in bundle-relocate.
  # -rpath,$CONDA_PREFIX/lib: the in-build DUMP step (temacs --temacs=pbootstrap) must load conda
  #   @rpath dylibs (Phase-1 finding). bundle-relocate deletes this rpath afterward.
  ./configure '"$EMACS_FLAGS"' "LDFLAGS=-Wl,-headerpad_max_install_names -Wl,-rpath,$CONDA_PREFIX/lib"
  make -j"$(sysctl -n hw.ncpu)"
  make install
  printf "%s/lib\n" "$CONDA_PREFIX" > "'"$OUT"'/conda-prefix-lib.txt"
'
echo ">> [3] locate the produced Emacs.app (--with-ns self-contained build → nextstep/Emacs.app)"
appsrc="$(find "$SRC" -maxdepth 3 -type d -name Emacs.app | head -1)"
[ -n "$appsrc" ] || { echo "FATAL: no Emacs.app produced — confirm the --with-ns self-contained build"; exit 1; }
echo "   found $appsrc"
rm -rf "$OUT/Emacs.app"; cp -R "$appsrc" "$OUT/Emacs.app"
echo ">> [4] discovery: otool inventory of the built (pre-reloc) app"
: > "$OUT/otool-prereloc.txt"
while IFS= read -r f; do
  file -b "$f" 2>/dev/null | grep -q Mach-O || continue
  { echo "-- $f"; otool -L "$f" | sed -n '2,$p'; } >> "$OUT/otool-prereloc.txt"
done < <(find "$OUT/Emacs.app" -type f)
sed -i '' "s|$HOME|~|g" "$OUT/otool-prereloc.txt" 2>/dev/null || true
echo ">> build-emacs: $OUT/Emacs.app ready (run 'mise run relocate' next)"
```

- [ ] **Step 2: Build and verify the candidate app exists and runs**

Run: `bash pipeline/build-emacs master`
Expected:
- Completes with `build-emacs: build/master/Emacs.app ready`.
- `build/master/Emacs.app/Contents/MacOS/Emacs` exists.
- `build/master/conda-prefix-lib.txt` contains a path ending in `.pixi/envs/default/lib`.
- `build/master/otool-prereloc.txt` shows the main binary depends on `@rpath/libgnutls.30.dylib`, `@rpath/libxml2.2.dylib`, `@rpath/libtree-sitter.0.26.dylib`, `@rpath/libncurses.6.dylib` (per Phase-1), plus `/usr/lib/*` system libs.

> **Validation point (ns self-contained):** if `make install` does **not** yield `nextstep/Emacs.app`, capture where it put the app and what the layout is, then adjust the `find` in Step 3 of the script. This is the one ns-build assumption that needs confirming on first run — record the actual layout for Task 7.

- [ ] **Step 3: Sanity-run on the host (still has pixi — confirms the build is valid, not yet the clean proof)**

Run: `build/master/Emacs.app/Contents/MacOS/Emacs --batch --eval '(princ (format "ok %s\n" emacs-version))'`
Expected: prints `ok 32.0.50` (or current master version).

- [ ] **Step 4: Commit**

```bash
git add pipeline/build-emacs
git commit -m "feat(phase2): build-emacs — build a relocatable-candidate GUI Emacs.app from the pixi env"
```

---

## Task 4: Relocate the real build + gate green locally

**Files:** none new — runs Task 2's stage on Task 3's output.

- [ ] **Step 1: Run the relocation on the real app**

Run: `bash pipeline/bundle-relocate master`
Expected: ends with `macho_gate: PASS (…/build/master/Emacs.app self-contained)`, exit 0.

- [ ] **Step 2: Independently re-run the gate (idempotent check) and inspect the closure**

Run:
```bash
source lib/macho.sh && macho_gate build/master/Emacs.app
ls build/master/Emacs.app/Contents/Frameworks/
otool -l build/master/Emacs.app/Contents/MacOS/Emacs | awk '/LC_RPATH/{f=1} f&&/path /{print; f=0}'
```
Expected:
- `macho_gate: PASS`.
- `Frameworks/` contains `libgnutls.30.dylib`, `libxml2.2.dylib`, `libtree-sitter.0.26.dylib`, `libncurses.6.dylib`, and the gnutls transitive closure (`libnettle*`, `libhogweed*`, `libp11-kit*`, `libtasn1*`, `libgmp*`, `libidn2*`, `libunistring*`).
- The main binary has an rpath `@loader_path/../Frameworks` and **no** `…/.pixi/…` rpath.

- [ ] **Step 3: Commit (record the validated closure in the message)**

```bash
git commit --allow-empty -m "test(phase2): relocate real master build — macho_gate green, closure bundled

Frameworks closure verified on osx-arm64: gnutls(+nettle/hogweed/p11-kit/tasn1/gmp/idn2/unistring),
libxml2, tree-sitter, ncurses. No .pixi refs/rpaths remain."
```

---

## Task 5: `scripts/cleanroom.sh` — the clean-VM DoD proof

**Files:**
- Create: `scripts/cleanroom.sh`

Runs on the **host** (tart needs non-nested virtualization). Proves the relocated app launches on a macOS VM that never had pixi.

- [ ] **Step 1: Write `scripts/cleanroom.sh`**

```bash
#!/usr/bin/env bash
# scripts/cleanroom.sh <version> — Phase 2 DoD proof.
# Clone a FRESH macOS VM that never had pixi, copy build/<version>/Emacs.app in, and prove it
# launches: `--batch` (forces dyld to resolve the full bundled closure with NO pixi present) +
# a GUI frame smoke. HOST-ONLY (do not run inside the pregate VM — no nested virtualization).
# Prereqs: tart (mise/aqua), sshpass; a base image (default cirruslabs macos base, admin/admin).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-master}"
APP_DIR="$HERE/build/$VERSION"
IMAGE="${CLEANROOM_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
VM="misemacs-cleanroom-$VERSION"
TART() { mise exec -- tart "$@"; }
[ -d "$APP_DIR/Emacs.app" ] || { echo "FATAL: $APP_DIR/Emacs.app missing — run 'mise run build && mise run relocate'"; exit 1; }

cleanup() { TART stop "$VM" >/dev/null 2>&1 || true; TART delete "$VM" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo ">> [1] clone a fresh clean VM ($IMAGE)"
TART clone "$IMAGE" "$VM"
echo ">> [2] boot (headless)"
TART run --no-graphics "$VM" >/dev/null 2>&1 &
ip=""; for _ in $(seq 1 60); do ip="$(TART ip "$VM" 2>/dev/null || true)"; [ -n "$ip" ] && break; sleep 2; done
[ -n "$ip" ] || { echo "FATAL: VM never got an IP"; exit 1; }
echo "   ip=$ip"
SSH() { sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "admin@$ip" "$@"; }

echo ">> [3] confirm the VM is clean (no pixi/conda) and copy the app in"
SSH 'command -v pixi conda >/dev/null 2>&1 && { echo "ABORT: VM already has pixi/conda"; exit 1; } || echo "   clean: no pixi/conda"'
( cd "$APP_DIR" && tar czf - Emacs.app ) | SSH 'mkdir -p ~/app && tar xzf - -C ~/app'

echo ">> [4] --batch (dyld must resolve the FULL bundled closure with no pixi) — THE gate"
SSH '~/app/Emacs.app/Contents/MacOS/Emacs --batch --eval "(princ (format \"ok %s\\n\" emacs-version))"'

echo ">> [5] GUI frame smoke (NS window system via the image auto-login session)"
# If a plain ssh can't reach the aqua GUI session, wrap with: launchctl asuser $(id -u admin) ...
SSH 'launchctl asuser $(id -u admin) ~/app/Emacs.app/Contents/MacOS/Emacs -Q \
       --eval "(run-with-timer 1 nil (lambda () (kill-emacs 0)))"' \
  && echo "   GUI frame OK" || { echo "FAIL: GUI frame launch"; exit 1; }

echo ">> cleanroom: PASS — self-contained on a clean macOS VM (no pixi)"
```

- [ ] **Step 2: Pull a base image once (if not present) and run the proof**

Run:
```bash
mise exec -- tart list | grep -q macos-sequoia-base || mise exec -- tart pull ghcr.io/cirruslabs/macos-sequoia-base:latest
bash scripts/cleanroom.sh master
```
Expected: `[4]` prints `ok 32.0.50`; `[5]` prints `GUI frame OK`; final `cleanroom: PASS`.

> **Validation points:** (a) `sshpass` must be installed (`mise exec -- pixi global install sshpass`, or document the host install). (b) If `--no-graphics` prevents the NS GUI session, drop it and rely on the image's auto-login; if `[5]` still can't reach the session over ssh, the `launchctl asuser` wrapper shown is the fallback. (c) `[4]` (`--batch`) is the **hard** DoD gate; record `[5]`'s exact working invocation in Task 7.

- [ ] **Step 3: Commit**

```bash
git add scripts/cleanroom.sh
git commit -m "feat(phase2): cleanroom.sh — fresh-tart-VM launch proof (no pixi)"
```

---

## Task 6: Wire mise tasks, gitignore, and pregate

**Files:**
- Modify: `mise.toml`, `.gitignore`, `.pregate/macos.sh`

- [ ] **Step 1: Add the Phase 2 tasks to `mise.toml`**

Append after the existing `[tasks.configure-check]` block:

```toml
[tasks.build]
description = "Phase 2: build a relocatable-candidate GUI Emacs.app from the per-version pixi env"
run = "bash pipeline/build-emacs master"

[tasks.relocate]
description = "Phase 2: bundle + relocate the built Emacs.app into a self-contained app (macho_gate)"
run = "bash pipeline/bundle-relocate master"

[tasks.test-macho]
description = "Phase 2: fixture tests for lib/macho.sh + pipeline/bundle-relocate (macOS host tools)"
run = "bash tests/macho_test.sh && bash tests/bundle-relocate_test.sh"

[tasks.cleanroom]
description = "Phase 2 DoD: launch the relocated Emacs.app in a fresh tart VM with no pixi"
run = "bash scripts/cleanroom.sh master"
```

- [ ] **Step 2: Ignore the build output**

Add to `.gitignore`:

```
# Phase 2 build/relocate output (ephemeral)
/build/
```

- [ ] **Step 3: Extend `.pregate/macos.sh` (static gate only — no nested VM)**

Replace `.pregate/macos.sh` with:

```sh
#!/bin/sh
# pregate macos recipe — shared body (orchestrator test+lint) then the Phase 2 build+relocate gate.
# Runs INSIDE the pregate VM; uses only host tools + pixi (no nested tart). The clean-VM launch
# (scripts/cleanroom.sh) is a host-side step, not run here.
. ./.pregate/common.sh
mise run test-macho
mise run build
mise run relocate    # ends with macho_gate — fails the pregate if the bundle isn't self-contained
```

- [ ] **Step 4: Verify the fast tasks run**

Run: `mise run test-macho`
Expected: both fixture suites print PASS; exit 0.

- [ ] **Step 5: Commit**

```bash
git add mise.toml .gitignore .pregate/macos.sh
git commit -m "build(phase2): mise tasks (build/relocate/test-macho/cleanroom) + pregate gate + gitignore"
```

---

## Task 7: Record findings + reconcile docs

**Files:**
- Modify: `docs/superpowers/validation-log.md`, `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`, `versions/master/mise.toml`

- [ ] **Step 1: Append the Phase 2 section to `docs/superpowers/validation-log.md`**

Add a dated section recording: the real Frameworks closure (from Task 4 Step 2); the confirmed ns `make install` app location (from Task 3 Step 2); the exact working `cleanroom` GUI invocation (Task 5); confirmation that `--batch` + GUI run with no pixi; and **Decision E** —

```markdown
### Decision E — host make/CLT fingerprint gap (spec §8): RESOLVED (record now, wire Phase 5)
Fold the toolchain identity of the host compiler into `toolchain_hash` when the fingerprint is
consumed (Phase 5): `xcode-select -p` + `clang --version` (the CLT/SDK build string). A runner-image
CLT/SDK bump then rebuilds all refs. No Phase-2 code; documented so Phase 5 wires it.
```

- [ ] **Step 2: Reconcile the umbrella spec**

- §9: replace the `@executable_path/../Frameworks` sketch with the actual scheme (build-time `-rpath,$CONDA_PREFIX/lib` for the dump; relocate adds depth-correct `@loader_path/<rel>` and deletes the conda rpath; ad-hoc re-sign per Mach-O).
- §6.2: change the ncurses row from "system `/usr/lib`, not bundled" to "**bundled** generically (GUI-only; the dylib only needs to resolve — terminfo/`-nw` deferred, §15)".
- §13: move "`--with-ns` Info.plist/extraction" and "`-nw` on system ncurses" open questions to resolved/deferred, pointing at §15.

- [ ] **Step 3: Fix the stale comment in `versions/master/mise.toml`**

Change the comment `# ncurses intentionally NOT requested → Emacs links system /usr/lib (spec §6.2).`
to: `# ncurses links from the pixi env (texinfo pulls it); GUI-only v1 bundles it generically in`
`# bundle-relocate, no terminfo work. emacs -nw is a post-Phase-4 fast-follow (spec §15).`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/validation-log.md docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md versions/master/mise.toml
git commit -m "docs(phase2): record build+relocation findings + Decision E; reconcile spec §6.2/§8/§9/§13"
```

---

## Phase 2 Definition of Done

- [ ] `mise run test-macho` green (fixture suites for `macho.sh` + `bundle-relocate`).
- [ ] `mise run build` produces `build/master/Emacs.app` that runs `--batch` on the host.
- [ ] `mise run relocate` ends with `macho_gate: PASS` — zero foreign dep paths, zero foreign rpaths, full @rpath closure in `Frameworks`.
- [ ] `mise run cleanroom` green: relocated app runs `--batch` (+ GUI frame) in a fresh tart VM with no pixi.
- [ ] Validation-log Phase 2 section written (closure, ns layout, cleanroom invocation, Decision E); spec §6.2/§8/§9/§13 reconciled; stale `versions/master/mise.toml` comment fixed.
- [ ] `emacs -nw`/terminfo confirmed **out of scope**, recorded for post-Phase-4 (spec §15).

## Self-Review (author)

**Spec coverage (Phase 2 row of §14 + §9):** "self-contained `.app` launches on a clean runner; `otool` gate green" → Tasks 4 (gate) + 5 (clean VM). `build-emacs` (§9.1) → Task 3. `bundle-relocate` generic over all Mach-O (§9.2) → Task 2. `macho.sh` + verify gate (§5, §9.2) → Task 1. Sign-last ad-hoc (§9.3, Decision C) → in `bundle-relocate` Step 2c. pregate clean-room intent (§11.3) → Task 6 (static gate in-VM) + Task 5 (host clean VM), with the nested-virt constraint documented. CLT fingerprint (§8, Decision E) → Task 7. `headerpad` + header-overflow risk (§12) → `build-emacs` LDFLAGS + macho.sh wrappers (`2>/dev/null || true` on rpath ops; gate catches incompleteness).

**Placeholder scan:** no TBD/TODO-as-work; every code step is complete runnable bash. The three "validation points" (ns app location, sshpass/GUI-session, base image) are explicit *confirm-and-adjust* checks with concrete fallbacks, not deferred work — they exist because the global rule forbids asserting unvalidated host behavior as fact.

**Type/name consistency:** function names used across files match `lib/macho.sh` definitions (`macho_is_macho`, `macho_class`, `macho_deps`, `macho_rpaths`, `macho_relpath`, `macho_set_id`, `macho_change`, `macho_add_rpath`, `macho_delete_rpath`, `macho_resign`, `macho_gate`). Path contract is consistent: `build-emacs` writes `build/<v>/{Emacs.app,conda-prefix-lib.txt}`; `bundle-relocate` reads exactly those (with `BUILD_ROOT` override for the fixture test); `cleanroom.sh` reads `build/<v>/Emacs.app`.

**Scope:** single subsystem (build + relocation), no decomposition needed. native-comp, signing-proper, packaging, CI, and `-nw` are explicitly excluded and routed to their phases.
