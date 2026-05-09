#!/usr/bin/env bash
# pre-autogen.sh — patches and setup that must run BEFORE autogen.
# Sourced (not exec'd) by scripts/build/autotools.sh so its env exports
# (GNULIB_SRCDIR) propagate into the autogen + make steps. See commit
# b738de9 for the original rationale of each patch.
set -euo pipefail

# Patch providers/Makefile.am — drop the explicit -lenchant from AM_LDFLAGS
# and add -undefined,dynamic_lookup so libenchant calls resolve at dlopen-
# time against jinx-mod's embedded libenchant copy.
if [ -f providers/Makefile.am ] && grep -q '^AM_LDFLAGS = -module -avoid-version -no-undefined' providers/Makefile.am; then
    sed -i.bak 's|^AM_LDFLAGS = -module -avoid-version -no-undefined.*|AM_LDFLAGS = -module -avoid-version -no-undefined -Wl,-undefined,dynamic_lookup $(GLIB_LIBS)|' providers/Makefile.am
    rm -f providers/Makefile.am.bak
fi

# Tell gnulib's bootstrap where to find the pre-cloned gnulib submodule.
# hydrate.sh populates libs/enchant/src/gnulib/ via versions.toml's
# `submodules = true` flag.
export GNULIB_SRCDIR="$(pwd)/gnulib"

# Wrap bootstrap so the autogen dispatch chain (which prefers ./autogen.sh
# over ./bootstrap) invokes it with --skip-git --skip-po.
# --skip-git tells bootstrap to skip git submodule operations (which
# otherwise fail because the submodule .git pointers reference paths
# outside the staged source tree). --skip-po skips po file downloads.
cat > autogen.sh <<'AUTOGEN_EOF'
#!/bin/sh
exec ./bootstrap --skip-git --skip-po "$@"
AUTOGEN_EOF
chmod +x autogen.sh
