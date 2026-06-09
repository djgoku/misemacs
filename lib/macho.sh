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
macho_resign()       { codesign --remove-signature "$1" 2>/dev/null || true; codesign -s - -f "$1"; }  # ad-hoc

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
