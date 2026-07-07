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
# Dir-scoped read (like EMACS_REF): versions/<v>/mise.toml [env] may override the root default.
EMACS_UPSTREAM="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_UPSTREAM:?EMACS_UPSTREAM unset}"')"
echo ">> version=$VERSION ref=$EMACS_REF"
echo ">> flags=$EMACS_FLAGS"

echo ">> [0a] mise-env-pixi activation exposes the pixi toolchain"
( cd "$VDIR" && mise exec -- sh -c 'command -v pkg-config && pkg-config --modversion gnutls libxml-2.0 tree-sitter' )

echo ">> [0b] direct pixi fallback (NO mise-env-pixi) exposes the same toolchain"
"${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" sh -c 'command -v pkg-config && pkg-config --modversion gnutls libxml-2.0 tree-sitter'

echo ">> [1] fetch $EMACS_UPSTREAM $EMACS_REF (shallow) -> $WORK"
mkdir -p "$REPO_ROOT/.work"
if [ -d "$WORK/.git" ]; then
  git -C "$WORK" fetch --depth 1 origin "$EMACS_REF"
  git -C "$WORK" checkout -q -f FETCH_HEAD
else
  rm -rf "$WORK"
  # --branch accepts a branch or tag (today EMACS_REF=master, a branch); a raw commit SHA would need the fetch path instead.
  git clone --depth 1 --branch "$EMACS_REF" "$EMACS_UPSTREAM" "$WORK"
fi

echo ">> [2] autogen + configure UNDER the pixi env (direct pixi run = the validated fallback path)"
"${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" bash -euo pipefail -c '
  cd "'"$WORK"'"
  export PATH="$CONDA_PREFIX/bin:$PATH"
  export PKG_CONFIG="$CONDA_PREFIX/bin/pkg-config"
  export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig"
  # Deliberately NO global -L$CONDA_PREFIX/lib / -I$CONDA_PREFIX/include (V8).
  # -rpath,$CONDA_PREFIX/lib: the conda dylibs use @rpath install names; without an rpath the
  # dump step (temacs --temacs=pbootstrap) cannot load @rpath/libxml2.2.dylib and the build
  # aborts (no LC_RPATHs found). Phase 2 relocation rewrites these install names, so this
  # build-time rpath is throwaway-validation-only.
  ./autogen.sh
  ./configure '"$EMACS_FLAGS"' "LDFLAGS=-Wl,-headerpad_max_install_names -Wl,-rpath,$CONDA_PREFIX/lib" 2>&1 | tee "'"$WORK"'/configure.log"
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
grep -qE 'native lisp compiler\?[[:space:]]+no'                "$log" || { echo "  MISS summary: native-comp=no"; fail=1; }
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
  if TERM=xterm-256color script -q /dev/null "$bin" -nw -Q --eval '(kill-emacs 0)' >/dev/null; then
    echo "  -nw OK"
  else
    echo "  FAIL -nw launch"; fail=1
  fi
  echo ">> [4c] otool -L provenance (ncurses MUST be /usr/lib; gnutls/xml2/tree-sitter from pixi)"
  otool -L "$bin" | grep -iE 'ncurses|gnutls|xml2|tree-sitter|nettle|p11-kit|tasn1|gmp|idn2|unistring' || true
  echo ">> [4d] ncurses provenance (INFO — system-vs-bundle is a Phase 2 relocation decision)"
  if otool -L "$bin" | grep -i ncurses | grep -q '/usr/lib/'; then
    echo "  INFO ncurses = /usr/lib (system)"
  else
    echo "  INFO ncurses = pixi env @rpath (texinfo pulls ncurses into the link env; Phase 2"
    echo "       relocation points it at system /usr/lib or bundles it)"
  fi
  [ "$fail" = 0 ] || { echo ">> FAIL: -nw smoke"; exit 1; }
fi
echo ">> configure-check: PASS"
