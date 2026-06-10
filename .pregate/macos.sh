#!/bin/sh
# pregate macos recipe — shared body (orchestrator test+lint, incl. the @tag :macos relocation
# integration test on Darwin), then the Phase 2 build -> relocate -> gate -> no-pixi launch, ALL in
# this one fresh disposable macOS VM. No nested virtualization, no sshpass, no separate image: the
# "clean machine" is this VM (fresh OS + toolchain only) with the pixi env moved aside before launch.
. ./.pregate/common.sh
mise run build
mise run relocate    # mix relocate ends with the static otool gate — fails pregate if not self-contained
mise run cleanroom   # moves versions/master/.pixi aside, then --batch (+ GUI frame) — the no-pixi proof
