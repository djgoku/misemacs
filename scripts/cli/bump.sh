#!/usr/bin/env bash
# bump.sh — atomic version bump.
#
# Usage:
#   mise run bump <pkg> <sha-or-prefix-or-latest>     (from-source git pkgs)
#   mise run bump conda:<name> <ver-or-latest>        (conda pkgs)
#
# From-source: validates worktree clean, fetches mirror, resolves sha,
# rewrites lockfile.toml, hydrates the one pkg. Does NOT build.
# Conda: edits mise.toml's [tools] entry, runs mise install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

[ "$#" -ge 2 ] || die "usage: mise run bump <pkg> <version>"
target="$1"
version="$2"

# --- Conda branch ---
if [[ "$target" == conda:* ]]; then
    name="${target#conda:}"
    grep -qE "^\"conda:$name\"" "$ROOT/mise.toml" || \
        die "conda:$name: not in mise.toml's [tools]; this is bump, not add"

    # Always update the constraint line — passing "latest" while mise.toml
    # has a specific pin must switch the pin to "latest" tracking, otherwise
    # `mise install` won't move forward.
    tmp=$(mktemp)
    awk -v name="conda:$name" -v ver="$version" '
        $0 ~ "^\""name"\"" {
            comment = ""
            if (match($0, /[[:space:]]+#.*$/)) comment = substr($0, RSTART, RLENGTH)
            printf "\"%s\" = \"%s\"%s\n", name, ver, comment; next
        }
        { print }
    ' "$ROOT/mise.toml" > "$tmp"
    mv "$tmp" "$ROOT/mise.toml"

    say "running mise install to refresh mise.lock for $target …"
    (cd "$ROOT" && mise install)

    say "bumped $target to $version"
    say "→ run: mise run build"
    exit 0
fi

# --- From-source git branch ---
pkg=$(resolve_pkg "$target")
require_clean_worktree "$pkg"

# Read versions.toml's repo URL.
repo=$(read_lockfile_field "$ROOT/$pkg/versions.toml" repo)
[ -n "$repo" ] || die "$pkg: no repo in versions.toml"

# Branch/tag to track for `latest`. Mac-port flavors live on non-default
# branches (e.g. emacs-mac-gnu_master_exp), so resolving the repo's default
# HEAD would grab the wrong line. Default to HEAD when versions.toml omits ref.
ref=$(read_lockfile_field "$ROOT/$pkg/versions.toml" ref)
[ -n "$ref" ] || ref="HEAD"

mirror="$ROOT/.cache/mirrors/$(basename "$pkg").git"
if [ ! -d "$mirror" ]; then
    say "cloning mirror $repo …"
    mkdir -p "$(dirname "$mirror")"
    git clone --mirror "$repo" "$mirror"
else
    say "fetching mirror $(basename "$mirror") …"
    git -C "$mirror" fetch --tags --prune >/dev/null
fi

# Resolve the sha.
case "$version" in
    latest)
        new_sha=$(git ls-remote "$repo" "$ref" | awk '{print $1}')
        [ -n "$new_sha" ] || die "git ls-remote $repo $ref returned empty"
        ;;
    *)
        # rev-parse handles both full and prefix shas; errors on ambiguity.
        new_sha=$(git -C "$mirror" rev-parse "$version" 2>/dev/null) || \
            die "could not resolve '$version' in mirror $mirror"
        ;;
esac

old_sha=$(read_lockfile_field "$ROOT/$pkg/lockfile.toml" sha)
if [ "$old_sha" = "$new_sha" ]; then
    say "$pkg: already at $new_sha; nothing to do"
    exit 0
fi

# Rewrite lockfile (atomic via _lib.sh).
write_lockfile_field "$ROOT/$pkg/lockfile.toml" sha "$new_sha"

# Per-package hydrate.
say "hydrating $pkg …"
(cd "$ROOT" && bash scripts/hydrate.sh "$pkg")

# Pretty summary.
new_subject=$(git -C "$mirror" log -1 --format=%s "$new_sha" 2>/dev/null || echo "")
say "bumped $pkg to ${new_sha:0:10}… (was ${old_sha:0:10}…)"
[ -n "$new_subject" ] && say "  subject: $new_subject"
say "→ run: mise run build"
