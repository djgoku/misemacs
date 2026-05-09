#!/usr/bin/env bash
# scripts/build/emacs-app.sh — port of rules/emacs_app.bzl.
#
# Usage: bash scripts/build/emacs-app.sh <pkg-dir>
#
# Runs Emacs's autogen+configure+make against mise-managed conda deps and
# bundles the result into a fully-relocatable Emacs.app at build/<basename>/.
#
# <pkg-dir> contents (relative to repo root):
#   build.toml             Build metadata; see fields below.
#   lockfile.toml          schema_version = 2 (read for src_sha provenance).
#   src/                   Hydrated git worktree pinned at the recorded sha.
#   src-sha.txt            Captured at hydrate time; embedded in the manifest.
#   src-commit-message.txt Captured at hydrate time; embedded in the manifest.
#
# build.toml fields:
#   src_repo = "https://..."                 (upstream URL — manifest provenance)
#   configure_args = ["--with-ns", ...]      (passed verbatim to ./configure)
#   bundle_enchant = true | false
#   bundle_vterm   = true | false
#   bundle_jinx    = true | false
#   enchant_dep      = "enchant"             (or "" — string name; resolves to
#                                               build/<name>/, omitted from the
#                                               bundling code path when "")
#   vterm_module_dep = "emacs-libvterm"      (same)
#   jinx_mod_dep     = "jinx-mod"            (same)
#   lib_deps  = ["conda-libpng", ...]        (CFLAGS/LDFLAGS/PKG_CONFIG_PATH from build/<name>/)
#   tool_deps = ["conda-pkg-config", ...]    (PATH/ACLOCAL_PATH from build/<name>/)
#
# Output:
#   build/<basename(pkg-dir)>/Emacs.app/   — the relocatable bundle.
# Atomic — the script writes to a tmpdir and `mv`s into place.

set -euo pipefail

PKG_DIR_ARG="${1:?usage: emacs-app.sh <pkg-dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"
PREFIX_ROOT="$ROOT/build"

PKG_DIR="$ROOT/${PKG_DIR_ARG#./}"
PKG_DIR="${PKG_DIR%/}"
PKG_NAME="$(basename "$PKG_DIR")"
FINAL_OUT="$PREFIX_ROOT/$PKG_NAME"

[ -f "$PKG_DIR/build.toml" ]    || { echo "emacs-app.sh: $PKG_DIR/build.toml missing" >&2; exit 1; }
[ -f "$PKG_DIR/lockfile.toml" ] || { echo "emacs-app.sh: $PKG_DIR/lockfile.toml missing" >&2; exit 1; }
[ -d "$PKG_DIR/src" ]           || { echo "emacs-app.sh: $PKG_DIR/src missing — run \`mise run hydrate $PKG_DIR_ARG\`" >&2; exit 1; }
assert_pkg_coherence "$PKG_DIR"

# --- TOML field readers (same shape as autotools.sh / cc-module.sh) ---
get_field() {
    awk -F' *= *' -v key="$2" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$1"
}
get_list() {
    awk -v key="$2" '
        $0 ~ "^[[:space:]]*"key"[[:space:]]*=[[:space:]]*\\[" {
            in_arr = 1
            sub(/.*\[/, "")
        }
        in_arr {
            line = $0
            while (match(line, /"[^"]*"/)) {
                s = substr(line, RSTART + 1, RLENGTH - 2)
                if (s != "") print s
                line = substr(line, RSTART + RLENGTH)
            }
            if (index($0, "]")) in_arr = 0
        }
    ' "$1"
}
get_bool() {
    # Returns "1" if `key = true`, else "0".
    local v
    v=$(get_field "$1" "$2")
    case "$v" in
        true|True|1) echo 1 ;;
        *)           echo 0 ;;
    esac
}

# --- Read build.toml ---
SRC_REPO=$(get_field "$PKG_DIR/build.toml" src_repo)
[ -n "$SRC_REPO" ] || { echo "emacs-app.sh: build.toml: src_repo is required" >&2; exit 1; }

CONFIGURE_ARGS=()
while IFS= read -r a; do CONFIGURE_ARGS+=("$a"); done < <(get_list "$PKG_DIR/build.toml" configure_args)

BUNDLE_ENCHANT=$(get_bool "$PKG_DIR/build.toml" bundle_enchant)
BUNDLE_VTERM=$(get_bool   "$PKG_DIR/build.toml" bundle_vterm)
BUNDLE_JINX=$(get_bool    "$PKG_DIR/build.toml" bundle_jinx)

ENCHANT_DEP=$(get_field      "$PKG_DIR/build.toml" enchant_dep)
VTERM_MODULE_DEP=$(get_field "$PKG_DIR/build.toml" vterm_module_dep)
JINX_MOD_DEP=$(get_field     "$PKG_DIR/build.toml" jinx_mod_dep)

LIB_DEPS=()
while IFS= read -r d; do LIB_DEPS+=("$d"); done < <(get_list "$PKG_DIR/build.toml" lib_deps)
TOOL_DEPS=()
while IFS= read -r d; do TOOL_DEPS+=("$d"); done < <(get_list "$PKG_DIR/build.toml" tool_deps)

if [ "$BUNDLE_JINX" = "1" ] && [ "$BUNDLE_ENCHANT" != "1" ]; then
    echo "emacs-app.sh: bundle_jinx requires bundle_enchant (jinx-mod statically links enchant but loads provider plugins from Contents/Frameworks/enchant-2/ at runtime)" >&2
    exit 1
fi

# --- Resolve dep prefixes (errors if any are missing) ---
LIB_PREFIXES=""
[ "${#LIB_DEPS[@]}" -gt 0 ] && LIB_PREFIXES=$(resolve_dep_prefixes "${LIB_DEPS[@]}")
TOOL_PREFIXES=""
[ "${#TOOL_DEPS[@]}" -gt 0 ] && TOOL_PREFIXES=$(resolve_dep_prefixes "${TOOL_DEPS[@]}")

# Resolve enchant/vterm/jinx prefixes (or "-" sentinels if not bundled).
ENCHANT_PREFIX="-"
[ -n "$ENCHANT_DEP" ] && ENCHANT_PREFIX="$(cd "$PREFIX_ROOT/$ENCHANT_DEP" && pwd)"
VTERM_PREFIX="-"
[ -n "$VTERM_MODULE_DEP" ] && VTERM_PREFIX="$(cd "$PREFIX_ROOT/$VTERM_MODULE_DEP" && pwd)"
JINX_PREFIX="-"
[ -n "$JINX_MOD_DEP" ] && JINX_PREFIX="$(cd "$PREFIX_ROOT/$JINX_MOD_DEP" && pwd)"

# Resolve the upstream commit-message file + the sha file.
COMMIT_MSG_FILE="-"
[ -f "$PKG_DIR/src-commit-message.txt" ] && COMMIT_MSG_FILE="$PKG_DIR/src-commit-message.txt"
SHA_FILE="-"
[ -f "$PKG_DIR/src-sha.txt" ] && SHA_FILE="$PKG_DIR/src-sha.txt"
SRC_SHA=""
[ "$SHA_FILE" != "-" ] && [ -f "$SHA_FILE" ] && SRC_SHA=$(tr -d '[:space:]' < "$SHA_FILE")

# --- Stage output ---
# Build everything into $STAGE; at the end atomic-mv to $FINAL_OUT.
# All subsequent script logic uses $OUT as if it were the final dir;
# $OUT just points at staging until the very end.
STAGE=$(mktemp -d)
OUT="$STAGE"
mkdir -p "$OUT"

# --- Stage source into a writable tmpdir; the worktree at SRC must remain ---
# clean so subsequent `git checkout` operations there work.
SRC_ORIG="$PKG_DIR/src"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$STAGE"' EXIT
cp -R "$SRC_ORIG" "$TMPDIR/src"
cd "$TMPDIR/src"

# --- Inject env from dep prefixes ---
# shellcheck disable=SC2086
tool_dep_path_export $TOOL_PREFIXES
# shellcheck disable=SC2086
dep_injection_export $LIB_PREFIXES

# ABS_DEPS is used by bundle_one() below; it expects a space-separated
# list of absolute prefixes to walk for @rpath dylib lookups.
ABS_DEPS="$LIB_PREFIXES"

# Emacs needs more than the generic dep-injection — extra C defines for
# select fd-set sizing on macOS, and explicit -l/framework links for gnutls'
# transitive closure (Emacs links libgnutls but not the rest of the chain).
export CFLAGS="$CFLAGS -DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT"
export LDFLAGS="$LDFLAGS -lhogweed -lnettle -ltasn1 -lgmp -framework Security -framework CoreFoundation"

# autoconf's AC_RUN_IFELSE compiles conftest binaries and immediately exec()s
# them. Without matching -Wl,-rpath entries the dynamic linker can't find the
# conda dylibs and aborts with "no LC_RPATH's found", which autoconf
# misinterprets as "cannot run C compiled programs → must be cross-compiling".
# Build an EXTRA_RPATHS string from every -L entry already in LDFLAGS.
EXTRA_RPATHS=""
for flag in $LDFLAGS; do
    case "$flag" in
        -L*)
            dir="${flag#-L}"
            EXTRA_RPATHS="$EXTRA_RPATHS -Wl,-rpath,$dir"
            ;;
    esac
done
export LDFLAGS="$LDFLAGS $EXTRA_RPATHS"

./autogen.sh

# Use a writable prefix so `make install` doesn't require root.
INSTALL_PREFIX="$TMPDIR/install"
mkdir -p "$INSTALL_PREFIX"

# shellcheck disable=SC2086
./configure "--prefix=$INSTALL_PREFIX" "${CONFIGURE_ARGS[@]}"

make bootstrap -j"$(sysctl -n hw.ncpu)"
make install

# Mac port builds the .app at mac/Emacs.app; NS port at nextstep/Emacs.app.
if [ -d mac/Emacs.app ]; then
    cp -R mac/Emacs.app "$OUT/Emacs.app"
else
    cp -R nextstep/Emacs.app "$OUT/Emacs.app"
fi

DIST="$OUT/Emacs.app"
LIBDIR="$DIST/Contents/Frameworks/lib"
SHAREDIR="$DIST/Contents/Frameworks/share"
SITE_LISP="$DIST/Contents/Resources/site-lisp"
EMACS_BIN="$DIST/Contents/MacOS/Emacs"
mkdir -p "$LIBDIR" "$LIBDIR/enchant-2" "$SHAREDIR/enchant-2" "$SITE_LISP"

# Recursive @rpath bundler. Walks otool -L output for the Emacs binary plus
# the wrapper modules + AppleSpell, copies every @rpath/<basename> library
# it finds in any dep prefix's lib/ into Contents/Frameworks/lib/, recursing
# on each copied dylib's own @rpath references. Writes seen basenames into
# a tmpdir tracker so we don't re-copy.
SEEN_DIR=$(mktemp -d)
bundle_one() {
    local libname="$1"
    [ -e "$SEEN_DIR/$libname" ] && return 0
    local src=""
    for prefix in $ABS_DEPS; do
        if [ -e "$prefix/lib/$libname" ]; then
            src="$prefix/lib/$libname"
            break
        fi
    done
    if [ -z "$src" ]; then
        echo "WARN: emacs-app: $libname not found in any dep prefix" >&2
        return 0
    fi
    # Resolve symlinks to the real file before copying.
    local real
    real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$src")
    cp "$real" "$LIBDIR/$libname"
    chmod u+w "$LIBDIR/$libname"
    touch "$SEEN_DIR/$libname"
    # Walk LC_LOAD_DYLIB refs in the just-bundled dylib. Two shapes:
    #   @rpath/<basename>   — recurse; resolved at runtime against the
    #                          bundle's @loader_path / @executable_path.
    #   /<absolute>/<base>  — if <base> is also bundleable (i.e., found in
    #                          some ABS_DEPS prefix's lib/), bundle it AND
    #                          rewrite this dylib's LC_LOAD_DYLIB from
    #                          <absolute> to @rpath/<base>. Catches conda-
    #                          built dylibs whose own LC_LOAD_DYLIB carries
    #                          a hardcoded conda path. System paths
    #                          (/usr/lib, /System) are left alone.
    local ref refbase refsrc
    while IFS= read -r ref; do
        case "$ref" in
            @rpath/*)
                bundle_one "${ref#@rpath/}"
                ;;
            /*)
                refbase=$(basename "$ref")
                refsrc=""
                for prefix in $ABS_DEPS; do
                    if [ -e "$prefix/lib/$refbase" ]; then
                        refsrc="$prefix/lib/$refbase"
                        break
                    fi
                done
                if [ -n "$refsrc" ]; then
                    local saved_ref="$ref"
                    bundle_one "$refbase"
                    install_name_tool -change "$saved_ref" "@rpath/$refbase" "$LIBDIR/$libname" 2>/dev/null || true
                fi
                ;;
        esac
    done < <(otool -L "$LIBDIR/$libname" | awk '/^\t/ {print $1}')
}

# Bundle dylibs referenced by Emacs + each module dep + AppleSpell.
for bin in "$EMACS_BIN" \
           "${VTERM_PREFIX:+$VTERM_PREFIX/lib/vterm-module.so}" \
           "${JINX_PREFIX:+$JINX_PREFIX/lib/jinx-mod.so}" \
           "${ENCHANT_PREFIX:+$ENCHANT_PREFIX/lib/enchant-2/enchant_applespell.so}"; do
    [ -n "$bin" ] && [ -f "$bin" ] || continue
    while IFS= read -r ref; do
        bundle_one "${ref#@rpath/}"
    done < <(otool -L "$bin" | awk '/^\t@rpath\// {print $1}')
done

# Wrapper modules + jinx.el.
if [ "$BUNDLE_VTERM" = "1" ] && [ -n "$VTERM_PREFIX" ] && [ "$VTERM_PREFIX" != "-" ]; then
    # Place vterm-module.dylib in site-lisp so emacs's default load-path
    # finds it; rename .so -> .dylib because module-file-suffix on macOS is
    # .dylib and (require 'vterm-module) only matches that suffix.
    cp "$VTERM_PREFIX/lib/vterm-module.so" "$SITE_LISP/vterm-module.dylib"
    install_name_tool -id "vterm-module.dylib" "$SITE_LISP/vterm-module.dylib" 2>/dev/null || true
    if [ -f "$VTERM_PREFIX/share/vterm-module/vterm.el" ]; then
        cp "$VTERM_PREFIX/share/vterm-module/vterm.el" "$SITE_LISP/vterm.el"
    fi
fi
if [ "$BUNDLE_JINX" = "1" ] && [ -n "$JINX_PREFIX" ] && [ "$JINX_PREFIX" != "-" ]; then
    cp "$JINX_PREFIX/lib/jinx-mod.so" "$SITE_LISP/jinx-mod.dylib"
    install_name_tool -id "jinx-mod.dylib" "$SITE_LISP/jinx-mod.dylib" 2>/dev/null || true
    if [ -f "$JINX_PREFIX/share/jinx-mod/jinx.el" ]; then
        cp "$JINX_PREFIX/share/jinx-mod/jinx.el" "$SITE_LISP/jinx.el"
    fi
fi

# AppleSpell provider + its config. Lives at the canonical
# Frameworks/lib/enchant-2/<provider>.so path so libenchant's relocate()
# (after the relocate-init constructor in jinx-mod calls
# enchant_set_prefix_dir(.../Frameworks)) finds providers at
# .../Frameworks/lib/enchant-2/.
if [ "$BUNDLE_ENCHANT" = "1" ] && [ -n "$ENCHANT_PREFIX" ] && [ "$ENCHANT_PREFIX" != "-" ]; then
    if [ -f "$ENCHANT_PREFIX/lib/enchant-2/enchant_applespell.so" ]; then
        cp "$ENCHANT_PREFIX/lib/enchant-2/enchant_applespell.so" "$LIBDIR/enchant-2/"
    fi
    if [ -f "$ENCHANT_PREFIX/share/enchant-2/AppleSpell.config" ]; then
        cp "$ENCHANT_PREFIX/share/enchant-2/AppleSpell.config" "$SHAREDIR/enchant-2/"
    fi
fi

# site-start.el — auto-loaded at Emacs startup. enchant relocation is
# handled by the relocate-init.c constructor inside jinx-mod, so site-start
# only needs to register doctor autoloads.
cat > "$SITE_LISP/site-start.el" <<'JINX_SITE_START_EOF'
;;; site-start.el --- moto-registry generated  -*- lexical-binding: t; -*-
(autoload 'moto-emacs-doctor "moto-emacs-doctor" nil t)
(autoload 'moto-emacs-doctor-batch "moto-emacs-doctor" nil t)
JINX_SITE_START_EOF

# moto-emacs-doctor.el — `M-x moto-emacs-doctor` reports pass/fail for the
# bundle's runtime wiring (jinx module loadable, enchant providers reachable,
# vterm-module present, etc.). Useful after relocation or filing an issue.
cat > "$SITE_LISP/moto-emacs-doctor.el" <<'MOTO_DOCTOR_EOF'
;;; moto-emacs-doctor.el --- Self-check the moto-built Emacs.app  -*- lexical-binding: t; -*-

(defun moto-emacs-doctor--frameworks ()
  (expand-file-name "../Frameworks"
                    (file-name-as-directory (invocation-directory))))

(defun moto-emacs-doctor--lib ()
  (expand-file-name "lib" (moto-emacs-doctor--frameworks)))

(defun moto-emacs-doctor--checks ()
  (let* ((libdir (moto-emacs-doctor--lib))
         (applespell (expand-file-name "enchant-2/enchant_applespell.so" libdir))
         (jinx-mod-name (file-name-with-extension "jinx-mod" module-file-suffix))
         (jinx-mod-path (locate-library jinx-mod-name t))
         (require-ok
          (condition-case _ (progn (require 'jinx) t) (error nil)))
         (module-load-ok
          (and jinx-mod-path
               (condition-case _
                   (progn (unless (fboundp 'jinx--mod-langs)
                            (module-load jinx-mod-path))
                          (fboundp 'jinx--mod-langs))
                 (error nil)))))
    (list
     (cons "Frameworks/lib/ exists"
           (file-directory-p libdir))
     (cons "AppleSpell provider .so present"
           (file-exists-p applespell))
     (cons "vterm-module is on load-path"
           (stringp (locate-library
                     (file-name-with-extension "vterm-module" module-file-suffix)
                     t)))
     (cons "(require 'vterm) succeeds"
           (condition-case _ (progn (require 'vterm) t) (error nil)))
     (cons "jinx-mod.<dylib|so> is on load-path"
           (stringp jinx-mod-path))
     (cons "(require 'jinx) succeeds"
           require-ok)
     (cons "jinx native module loaded"
           module-load-ok)
     (cons "enchant returns >=1 language"
           (and module-load-ok (consp (jinx--mod-langs)))))))

;;;###autoload
(defun moto-emacs-doctor ()
  "Verify the moto-built Emacs.app bundle's runtime wiring."
  (interactive)
  (require 'cl-lib)
  (with-output-to-temp-buffer "*moto-emacs-doctor*"
    (let* ((checks (moto-emacs-doctor--checks))
           (passed (cl-count-if #'cdr checks))
           (total  (length checks)))
      (princ (format "moto-emacs-doctor: %d/%d checks passed\n\n" passed total))
      (dolist (c checks)
        (princ (format "%s %s\n" (if (cdr c) "[PASS]" "[FAIL]") (car c))))
      (princ (format "\ninvocation-directory : %s\n" (invocation-directory)))
      (princ (format "Frameworks/          : %s\n" (moto-emacs-doctor--frameworks)))
      (princ (format "Frameworks/lib       : %s\n" (moto-emacs-doctor--lib)))
      (princ (format "module-file-suffix   : %s\n" module-file-suffix))
      (when (fboundp 'jinx--mod-langs)
        (let ((langs (jinx--mod-langs)))
          (princ (format "\nenchant languages (%d):\n" (length langs)))
          (dolist (l langs)
            (princ (format "  %-8s -> %s\n" (car l) (cdr l)))))))))

;;;###autoload
(defun moto-emacs-doctor-batch ()
  "Run moto-emacs-doctor non-interactively. Exit code = number of failed checks."
  (require 'cl-lib)
  (let* ((checks (moto-emacs-doctor--checks))
         (passed (cl-count-if #'cdr checks))
         (total  (length checks))
         (failed (- total passed)))
    (princ (format "moto-emacs-doctor: %d/%d checks passed\n" passed total))
    (dolist (c checks)
      (princ (format "%s %s\n" (if (cdr c) "[PASS]" "[FAIL]") (car c))))
    (kill-emacs failed)))

(provide 'moto-emacs-doctor)
;;; moto-emacs-doctor.el ends here
MOTO_DOCTOR_EOF

# LC_RPATH cleanup. Each binary built against the conda envs has the conda
# paths baked into its LC_RPATH; strip those and add the bundle-relative
# path. Layout: every linked dylib is under Contents/Frameworks/lib/, so
# Emacs binary points at .../Frameworks/lib; wrapper modules in Frameworks/
# lib/ point at @loader_path/; jinx-mod at .../site-lisp/ walks back to
# .../Frameworks/lib.
#
# Strip every absolute-path LC_RPATH from $1, keeping only @-relative
# entries (@executable_path/..., @loader_path/...). Either kind of absolute
# path defeats relocatability: the bundled dyld would resolve @rpath/<lib>
# through the absolute path first, finding the conda install dir instead of
# the bundled lib.
strip_absolute_rpaths() {
    local target="$1"
    while IFS= read -r rpath; do
        case "$rpath" in
            @*) ;;  # keep
            /*) install_name_tool -delete_rpath "$rpath" "$target" 2>/dev/null || true ;;
        esac
    done < <(otool -l "$target" | awk '/LC_RPATH/{flag=1;next} flag && /path /{print $2; flag=0}')
}

strip_absolute_rpaths "$EMACS_BIN"
install_name_tool -add_rpath @executable_path/../Frameworks/lib "$EMACS_BIN" 2>/dev/null || true

VTERM_MOD_BUNDLED="$SITE_LISP/vterm-module.dylib"
if [ -f "$VTERM_MOD_BUNDLED" ]; then
    strip_absolute_rpaths "$VTERM_MOD_BUNDLED"
    install_name_tool -add_rpath @loader_path/../../Frameworks/lib "$VTERM_MOD_BUNDLED" 2>/dev/null || true
fi

if [ -f "$SITE_LISP/jinx-mod.dylib" ]; then
    strip_absolute_rpaths "$SITE_LISP/jinx-mod.dylib"
    install_name_tool -add_rpath @loader_path/../../Frameworks/lib "$SITE_LISP/jinx-mod.dylib" 2>/dev/null || true
fi

# Strip absolute LC_RPATHs from subsidiary Emacs binaries (etags, ebrowse,
# emacsclient, hexl, movemail, …) and add a bundle-relative rpath so they
# can resolve @rpath/lib*.dylib at runtime. These binaries DO load dylibs
# (e.g., libhogweed/libnettle/libgmp via @rpath/...) — without an rpath the
# loader fails with "Library not loaded: @rpath/libhogweed.6.dylib /
# Reason: no LC_RPATH's found".
#
# Path: each subsidiary binary lives at Contents/MacOS/{bin,libexec}/ (one
# level deeper than the main Emacs binary). @executable_path is the binary's
# containing dir, so two `..` walks up to Contents, then we append /Frameworks/lib.
while IFS= read -r subbin; do
    [ -z "$subbin" ] && continue
    [ -f "$subbin" ] || continue
    strip_absolute_rpaths "$subbin"
    install_name_tool -add_rpath @executable_path/../../Frameworks/lib "$subbin" 2>/dev/null || true
done < <(find "$DIST/Contents/MacOS/bin" "$DIST/Contents/MacOS/libexec" -type f -perm +111 2>/dev/null || true)

# === STAGE: Build manifest ===
# Generate Contents/Resources/build-manifest.org documenting what's in the
# bundle: emacs source SHA + repo, conda packages + versions (from `mise
# list`), configure flags, and the actual bundled dylib + module list.
MANIFEST="$DIST/Contents/Resources/build-manifest.org"
{
    cat <<'MANIFEST_HEADER_EOF'
#+TITLE: Emacs.app build manifest
#+OPTIONS: toc:nil

* Build context
:PROPERTIES:
MANIFEST_HEADER_EOF
    printf ':built_at:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf ':host_os:     %s\n' "$(uname -s)"
    printf ':host_arch:   %s-%s\n' "$(uname -m)" "$(uname -r)"
    printf ':emacs_sha:   %s\n' "$SRC_SHA"
    printf ':emacs_repo:  %s\n' "$SRC_REPO"
    printf ':builder:     %s\n' "mise run build"
    printf ':END:\n'
    if [ "$COMMIT_MSG_FILE" != "-" ] && [ -f "$COMMIT_MSG_FILE" ]; then
        cat <<'MANIFEST_UPSTREAM_HDR_EOF'

* Upstream emacs commit

#+begin_src
MANIFEST_UPSTREAM_HDR_EOF
        cat "$COMMIT_MSG_FILE"
        cat <<'MANIFEST_UPSTREAM_FTR_EOF'
#+end_src
MANIFEST_UPSTREAM_FTR_EOF
    fi
    cat <<'MANIFEST_FROMSOURCE_EOF'

* From-source targets

The exact SHA for each from-source target lives in its
=lockfile.toml=. Pin a single moto-registry commit and run
=git show $MOTO_SHA:libs/jinx-mod/lockfile.toml= (etc.) to recover
the full provenance.

| target              | lockfile                          |
|---------------------|-----------------------------------|
| pkgs/emacs          | pkgs/emacs/lockfile.toml          |
| libs/enchant        | libs/enchant/lockfile.toml        |
| libs/jinx-mod       | libs/jinx-mod/lockfile.toml       |
| libs/emacs-libvterm | libs/emacs-libvterm/lockfile.toml |

* Conda-provided libraries and tools (via mise / conda-forge)

#+begin_src
MANIFEST_FROMSOURCE_EOF
    mise list 2>/dev/null | awk '$1 ~ /^conda:/ {printf "%-30s  %s\n", $1, $2}'
    cat <<'MANIFEST_FLAGS_EOF'
#+end_src

* Configure flags

#+begin_src
MANIFEST_FLAGS_EOF
    printf '%s\n' "${CONFIGURE_ARGS[*]}"
    cat <<'MANIFEST_BUNDLED_HDR_EOF'
#+end_src

* Bundled libraries

Listing of =Contents/Frameworks/lib/= (linked dylibs that the
=bundle_one= recursive walker pulled in for the binary, the wrapper
modules, and AppleSpell):

#+begin_src
MANIFEST_BUNDLED_HDR_EOF
    (cd "$DIST/Contents/Frameworks/lib" && ls -1 | sort) 2>/dev/null || true
    cat <<'MANIFEST_ENCHANT_EOF'
#+end_src

Plus, in =Contents/Frameworks/lib/enchant-2/=:

#+begin_src
MANIFEST_ENCHANT_EOF
    (cd "$DIST/Contents/Frameworks/lib/enchant-2" && ls -1 | sort) 2>/dev/null || true
    cat <<'MANIFEST_SITELISP_EOF'
#+end_src

And, in =Contents/Resources/site-lisp/= (Emacs modules + elisp):

#+begin_src
MANIFEST_SITELISP_EOF
    (cd "$DIST/Contents/Resources/site-lisp" && ls -1 | sort) 2>/dev/null || true
    cat <<'MANIFEST_FOOTER_EOF'
#+end_src

* Reproduce

#+begin_src bash
mise run bootstrap
mise run build
#+end_src
MANIFEST_FOOTER_EOF
} > "$MANIFEST"

# Codesign ad-hoc. Sign files individually (`\;` not `+`) — batched mode
# engages bundle-aware validation that fails on this layout.
#
# The main Emacs binary needs out-of-bundle signing: codesign auto-detects
# the bundle context when signing a file at $bundle/Contents/MacOS/<exe>
# and walks the bundle's subcomponents. It then trips over the Mac port's
# Contents/MacOS/libexec/<arch>/ directory (looks like a sub-bundle but
# isn't), aborts mid-sign, and leaves the binary with an invalid signature
# that macOS SIGKILLs at launch. Signing a copy outside the bundle avoids
# the walker entirely.
find "$DIST" -type f \( -name "*.dylib" -o -name "*.so" \) \
    -exec codesign --force --sign - {} \;
find "$DIST/Contents/MacOS" -type f -perm +111 ! -name Emacs \
    -exec codesign --force --sign - {} \;
solo_dir=$(mktemp -d)
cp "$EMACS_BIN" "$solo_dir/Emacs"
codesign --force --sign - "$solo_dir/Emacs"
mv "$solo_dir/Emacs" "$EMACS_BIN"
rmdir "$solo_dir"

# --- Atomic install ---
mkdir -p "$PREFIX_ROOT"
rm -rf "$FINAL_OUT"
mv "$STAGE" "$FINAL_OUT"
# trap on EXIT will rm $TMPDIR + $STAGE — but we just moved $STAGE.
# Override the trap so it doesn't try to rm a non-existent dir.
trap 'rm -rf "$TMPDIR"' EXIT
