#!/usr/bin/env bash
# release.sh — package build/<flavor>/Emacs.app for a misemacs release.
#
# Usage: release.sh <flavor> <version>
#
# Produces, under build/release/<version>/:
#   misemacs-<version>-macos-arm64.tar.gz   (the bundle, deterministic gzip-tarball)
#   SHASUMS256.txt                           (sha256 of the tarball)
#   build-manifest.org                       (copy of the in-bundle manifest)
#   RELEASE_NOTES.md                         (auto-generated body for gh release)
set -euo pipefail

FLAVOR="${1:-}"
VERSION="${2:-}"
[ -n "$FLAVOR" ]  || { echo "release.sh: missing flavor argument (e.g. emacs-master)" >&2; exit 1; }
[ -n "$VERSION" ] || { echo "release.sh: missing version argument (e.g. emacs-master-2026.05.27)" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

APP="build/$FLAVOR/Emacs.app"
EMACS_BIN="$APP/Contents/MacOS/Emacs"
MANIFEST="$APP/Contents/Resources/build-manifest.org"

[ -d "$APP" ]                  || { echo "release.sh: $APP not found — run 'mise run validate' first" >&2; exit 2; }
[ -x "$EMACS_BIN" ]            || { echo "release.sh: $EMACS_BIN not executable" >&2; exit 2; }
[ -f "$MANIFEST" ]             || { echo "release.sh: $MANIFEST not found" >&2; exit 2; }

# Dirty-tree gate: CI never bypasses; local opt-in via env var.
if [ -n "$(git status --porcelain)" ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ] || [ -z "${MISEMACS_RELEASE_ALLOW_DIRTY:-}" ]; then
        echo "release.sh: git tree dirty; refusing to release" >&2
        echo "  (set MISEMACS_RELEASE_ALLOW_DIRTY=1 for local dry-runs)" >&2
        exit 2
    fi
fi

# Resolve host os/arch — only macos-arm64 implemented at v0.
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) ASSET_OS=macos; ASSET_ARCH=arm64 ;;
    *)            echo "release.sh: unsupported host $(uname -s)/$(uname -m); only Darwin/arm64 implemented at v0" >&2; exit 1 ;;
esac

ASSET_BASE="misemacs-${VERSION}-${ASSET_OS}-${ASSET_ARCH}"
OUT_DIR="build/release/${VERSION}"
TARBALL="${OUT_DIR}/${ASSET_BASE}.tar.gz"

mkdir -p "$OUT_DIR"

echo "release.sh: preconditions OK (version=$VERSION, asset_base=$ASSET_BASE)"

# --- Stage Emacs.app under a wrapper directory matching ASSET_BASE ---
# (aqua's {{.AssetWithoutExt}} template expects this top-level layout.)
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$ASSET_BASE"
# COPYFILE_DISABLE=1 prevents AppleDouble (._*) sidecar files in the copy.
COPYFILE_DISABLE=1 cp -R "$APP" "$STAGE/$ASSET_BASE/Emacs.app"

# --- Deterministic tarball with GNU tar from conda:tar ---
# GNU tar (gtar) supports --sort=name; macOS BSD tar does not.
GTAR="$(mise where conda:tar)/bin/tar"
[ -x "$GTAR" ] || { echo "release.sh: GNU tar from conda:tar not found at $GTAR" >&2; exit 1; }

# Produce the .tar uncompressed first, then gzip with -n (no embedded mtime/filename).
COPYFILE_DISABLE=1 "$GTAR" \
    --create \
    --file - \
    --directory "$STAGE" \
    --mtime=@0 \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --format=ustar \
    "$ASSET_BASE" \
    | gzip -n > "$TARBALL"

echo "release.sh: produced $TARBALL ($(du -h "$TARBALL" | cut -f1))"

# --- SHA256 checksums ---
# `shasum -a 256` emits two-space-separated <hash><sp><sp><filename>.
# We invoke from inside OUT_DIR so the filename is bare (no path prefix).
( cd "$OUT_DIR" && shasum -a 256 "${ASSET_BASE}.tar.gz" ) > "${OUT_DIR}/SHASUMS256.txt"
echo "release.sh: wrote ${OUT_DIR}/SHASUMS256.txt"

# --- Build manifest (verbatim copy from inside the bundle) ---
cp "$MANIFEST" "${OUT_DIR}/build-manifest.org"
echo "release.sh: copied build-manifest.org"

# --- inputs.sha256 — build-input fingerprint. release.yaml records this on
# each release and compares it next run to skip rebuilding/re-releasing this
# flavor when nothing changed. ---
elixir scripts/cli/inputs_hash.exs "$FLAVOR" > "${OUT_DIR}/inputs.sha256"
echo "release.sh: wrote ${OUT_DIR}/inputs.sha256 ($(cat "${OUT_DIR}/inputs.sha256"))"

# --- Auto-generated RELEASE_NOTES.md ---
# Pulls emacs SHA + upstream commit subject + from-source pkg SHAs from
# the lockfile.toml files committed in this repo. Conda library versions
# come from the build manifest copy.
emacs_sha=$(awk -F'"' '/^sha/{print $2}' "pkgs/$FLAVOR/lockfile.toml")
emacs_subject=$(git -C "pkgs/$FLAVOR/src" log -1 --pretty=format:%s 2>/dev/null || echo "(no upstream subject available)")
emacs_url=$(awk -F'"' '/^repo/{print $2}' "pkgs/$FLAVOR/versions.toml")
emacs_ref=$(awk -F'"' '/^ref/{print $2}' "pkgs/$FLAVOR/versions.toml")
emacs_repo=${emacs_url#https://github.com/}

enchant_sha=$(awk -F'"' '/^sha/{print $2}' libs/enchant/lockfile.toml)
jinx_sha=$(awk -F'"' '/^sha/{print $2}' libs/jinx-mod/lockfile.toml)
vterm_sha=$(awk -F'"' '/^sha/{print $2}' libs/emacs-libvterm/lockfile.toml)
enchant_url=$(awk -F'"' '/^repo/{print $2}' libs/enchant/versions.toml)
jinx_url=$(awk -F'"' '/^repo/{print $2}' libs/jinx-mod/versions.toml)
vterm_url=$(awk -F'"' '/^repo/{print $2}' libs/emacs-libvterm/versions.toml)

short() { printf '%s' "${1:0:10}"; }

cat > "${OUT_DIR}/RELEASE_NOTES.md" <<NOTES
# misemacs ${VERSION}

Hermetically-built relocatable \`Emacs.app\` for macOS, via mise + conda-forge.

## Upstream

- **${FLAVOR}** (\`${emacs_repo}\` @ \`${emacs_ref}\`) @ [\`$(short "$emacs_sha")\`](${emacs_url}/commit/${emacs_sha}) — ${emacs_subject}

## From-source packages

| Package | SHA | Source |
|---|---|---|
| libs/enchant | \`$(short "$enchant_sha")\` | [${enchant_url}/commit/${enchant_sha}](${enchant_url}/commit/${enchant_sha}) |
| libs/jinx-mod | \`$(short "$jinx_sha")\` | [${jinx_url}/commit/${jinx_sha}](${jinx_url}/commit/${jinx_sha}) |
| libs/emacs-libvterm | \`$(short "$vterm_sha")\` | [${vterm_url}/commit/${vterm_sha}](${vterm_url}/commit/${vterm_sha}) |

## Verify

\`\`\`
shasum -a 256 -c SHASUMS256.txt
gh attestation verify ${ASSET_BASE}.tar.gz --owner djgoku
\`\`\`

## Conda libraries

Pinned via \`mise.lock\`. Full list in the attached \`build-manifest.org\`.

NOTES

echo "release.sh: wrote ${OUT_DIR}/RELEASE_NOTES.md"
