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
