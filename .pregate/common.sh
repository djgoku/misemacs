#!/bin/sh
# shared pregate steps, sourced by macos.sh + linux.sh. cwd = source tree.
# Avoid exit codes 10-12 (reserved by pregate).
set -eu
ver=$(mise --version 2>/dev/null) || ver=""
[ -n "$ver" ] || { echo "FATAL: mise missing/broken in the $PREGATE_OS image"; exit 1; }
# Trust the repo-root config AND each per-version config. pipeline/build-emacs cd's into
# versions/<ref>/ where `mise exec` reads versions/<ref>/mise.toml — untrusted in a fresh VM
# (the host has it trusted, so this gap only surfaces in pregate). `mise trust --all` walks UP
# (parents), not into subdirs, so the nested configs must be trusted explicitly; the glob keeps
# the "add a version = data only" rule (no recipe edit when a new versions/<ref>/ appears).
for _cfg in ./mise.toml versions/*/mise.toml; do
  [ -f "$_cfg" ] && mise trust "$_cfg" >/dev/null 2>&1 || true
done
mise install        # provision the pinned toolchain in the fresh VM
mise run test
mise run lint
