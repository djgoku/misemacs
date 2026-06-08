#!/bin/sh
# shared pregate steps, sourced by macos.sh + linux.sh. cwd = source tree.
# Avoid exit codes 10-12 (reserved by pregate).
set -eu
ver=$(mise --version 2>/dev/null) || ver=""
[ -n "$ver" ] || { echo "FATAL: mise missing/broken in the $PREGATE_OS image"; exit 1; }
mise trust >/dev/null 2>&1 || true
mise install        # provision the pinned toolchain in the fresh VM
mise run test
mise run lint
