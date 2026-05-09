#!/usr/bin/env bash
# bootstrap.sh — post-autogen build-tool shims and patches.
# Sourced (not exec'd) by scripts/build/autotools.sh so its PATH change
# (the groff shim) propagates into the make step.
set -euo pipefail

mkdir -p shim-bin
# groff shim: macOS 14+ removed /usr/bin/groff; enchant's doc/Makefile needs it.
printf '#!/bin/sh\ncat /dev/null\n' > shim-bin/groff
chmod +x shim-bin/groff
export PATH="$(pwd)/shim-bin:$PATH"

# Fallback: if pre-autogen's .am patch did not propagate to the regenerated
# Makefile.in (upstream automake syntax drift), patch in place.
if [ -f providers/Makefile.in ] && ! grep -q 'dynamic_lookup' providers/Makefile.in; then
    sed -i.bak 's|^AM_LDFLAGS = -module -avoid-version -no-undefined .*|AM_LDFLAGS = -module -avoid-version -no-undefined -Wl,-undefined,dynamic_lookup $(GLIB_LIBS)|' providers/Makefile.in
    rm -f providers/Makefile.in.bak
fi
