#!/usr/bin/env bash
# hydrate.sh — populate the moto-registry build cache.
#
# For tarball packages (source.type = "tarball"): downloads the tarball into
# the package directory, verifying sha256.
#
# For git packages (source.type = "git"): maintains a bare mirror clone under
# .cache/mirrors/<pkg>.git and a detached worktree at <pkg>/src pinned to the
# sha recorded in the package's lockfile.toml for versions.toml's `current`.
#
# Idempotent: skips downloads when the tarball is already present and matches
# the declared sha256; reuses existing mirrors/worktrees when they already
# point at the desired sha.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

get() {
    # get <toml-path> <key>
    # Returns the value for the first `key = "..."` match in <toml-path>, or empty.
    awk -F' *= *' -v key="$2" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$1"
}

get_section_field() {
    # get_section_field <lockfile.toml> <version-key> <field-name>
    awk -v want="$2" -v field="$3" '
        /^\[versions\./ { in_section = ($0 ~ "\"" want "\"\\]$") }
        in_section && $0 ~ "^"field"[[:space:]]*=" {
            if (match($0, /"[^"]*"/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
            }
            exit
        }
    ' "$1"
}

hydrate_tarball() {
    local pkg_dir="$1"
    local toml="$pkg_dir/versions.toml"
    local lockfile="$pkg_dir/lockfile.toml"
    local pkg_name
    pkg_name=$(basename "$pkg_dir")

    if [ ! -f "$lockfile" ]; then
        echo "hydrate: $pkg_dir: missing lockfile.toml" >&2
        return 1
    fi

    local schema
    schema=$(get "$lockfile" "schema_version")
    if [ "$schema" != "2" ]; then
        echo "hydrate: $pkg_dir: schema_version=$schema (expected 2). Run scripts/migrate-lockfiles.sh." >&2
        return 1
    fi

    local current sha256 url
    current=$(get "$lockfile" "version")
    sha256=$(get "$lockfile" "sha256")
    url=$(get "$lockfile" "url")
    if [ -z "$current" ] || [ -z "$sha256" ]; then
        echo "hydrate: $pkg_dir: missing version or sha256 in lockfile.toml" >&2
        return 1
    fi

    # URL: prefer per-version `url` in the lockfile (for outliers like
    # libvterm/tree-sitter); fall back to versions.toml's url_tmpl with {version}
    # substitution.
    if [ -z "$url" ]; then
        local url_tmpl
        url_tmpl=$(get "$toml" "url_tmpl")
        if [ -z "$url_tmpl" ]; then
            echo "hydrate: $pkg_dir: no url in lockfile section and no url_tmpl in versions.toml" >&2
            return 1
        fi
        url="${url_tmpl//\{version\}/$current}"
    fi

    # Derive stable filename: <pkg_name>.<archive-ext>
    local ext
    case "$url" in
        *.tar.xz)  ext="tar.xz" ;;
        *.tar.gz)  ext="tar.gz" ;;
        *.tar.bz2) ext="tar.bz2" ;;
        *.tgz)     ext="tgz" ;;
        *)
            echo "hydrate: $pkg_dir: unrecognized archive extension in URL: $url" >&2
            return 1
            ;;
    esac
    local stable_name="$pkg_name.$ext"
    local dest="$pkg_dir/$stable_name"

    # Remove stale versioned tarballs (any *.tar.* that isn't the stable one).
    for f in "$pkg_dir"/*.tar.* "$pkg_dir"/*.tgz; do
        [ -f "$f" ] || continue
        if [ "$(basename "$f")" != "$stable_name" ]; then
            echo "hydrate: $pkg_dir: removing stale tarball $(basename "$f")"
            rm -f "$f"
        fi
    done

    if [ -f "$dest" ]; then
        local actual
        actual=$(shasum -a 256 "$dest" | awk '{print $1}')
        if [ "$actual" = "$sha256" ]; then
            echo "hydrate: $pkg_dir: tarball present and verified ($current)"
            return 0
        fi
        echo "hydrate: $pkg_dir: tarball sha256 mismatch — redownloading" >&2
        rm -f "$dest"
    fi

    echo "hydrate: $pkg_dir: downloading $url"
    curl -L --fail -o "$dest" "$url"

    local actual
    actual=$(shasum -a 256 "$dest" | awk '{print $1}')
    if [ "$actual" != "$sha256" ]; then
        echo "hydrate: $pkg_dir: sha256 mismatch after download: got $actual, want $sha256" >&2
        rm -f "$dest"
        return 1
    fi

    echo "hydrate: $pkg_dir: downloaded and verified ($current)"
}

hydrate_git() {
    local pkg_dir="$1"
    local toml="$pkg_dir/versions.toml"
    local lockfile="$pkg_dir/lockfile.toml"

    local repo schema sha
    repo=$(get "$toml" "repo")

    if [ ! -f "$lockfile" ]; then
        echo "hydrate: $pkg_dir: missing lockfile.toml" >&2
        return 1
    fi

    schema=$(get "$lockfile" "schema_version")
    if [ "$schema" != "2" ]; then
        echo "hydrate: $pkg_dir: schema_version=$schema (expected 2). Run scripts/migrate-lockfiles.sh." >&2
        return 1
    fi

    sha=$(get "$lockfile" "sha")
    if [ -z "$repo" ] || [ -z "$sha" ]; then
        echo "hydrate: $pkg_dir: missing repo (versions.toml) or sha (lockfile.toml)" >&2
        return 1
    fi

    local pkg_name
    pkg_name=$(basename "$pkg_dir")
    local mirror="$ROOT/.cache/mirrors/${pkg_name}.git"

    if [ ! -d "$mirror" ]; then
        echo "hydrate: $pkg_dir: cloning mirror $repo"
        mkdir -p "$(dirname "$mirror")"
        git clone --mirror "$repo" "$mirror"
    else
        echo "hydrate: $pkg_dir: fetching mirror $(basename "$mirror")"
        git -C "$mirror" fetch --tags --prune >/dev/null
    fi

    # Resolve worktree path to an absolute path — `git -C $mirror worktree add`
    # resolves relative paths against the mirror's cwd (the bare-repo dir), not
    # the invoker's cwd, so a relative "$pkg_dir/src" would land inside the
    # mirror. Using $ROOT (already absolute) sidesteps that.
    local worktree="$ROOT/${pkg_dir#./}/src"
    if [ -e "$worktree" ]; then
        local cur_sha
        cur_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)
        if [ "$cur_sha" != "$sha" ]; then
            echo "hydrate: $pkg_dir: removing stale worktree (HEAD $cur_sha != $sha)"
            git -C "$mirror" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
        fi
    fi

    if [ ! -e "$worktree" ]; then
        echo "hydrate: $pkg_dir: checking out worktree at $sha"
        git -C "$mirror" worktree add --detach "$worktree" "$sha"
    fi

    # Optional: init git submodules if versions.toml's [source] block
    # has `submodules = true`. Default: false. Used by libs/enchant for
    # its gnulib submodule (gnulib's bootstrap script operates on a
    # pre-cloned submodule, not a network-cloned working tree).
    local submodules
    submodules=$(get "$toml" "submodules")
    if [ "$submodules" = "true" ]; then
        echo "hydrate: $pkg_dir: initializing git submodules"
        git -C "$worktree" submodule update --init --recursive
    fi

    # Capture the upstream commit's SHA + full message (subject + body)
    # next to the worktree. scripts/build/emacs-app.sh reads these and
    # embeds them in Contents/Resources/build-manifest.org. mise's blake3
    # freshness is by content, so identical files don't re-invalidate the
    # [deps.pkgs-emacs-master] hash on a no-op rehydrate.
    printf '%s\n' "$sha" > "$pkg_dir/src-sha.txt"
    git -C "$mirror" log -1 --format=%B "$sha" > "$pkg_dir/src-commit-message.txt"

    echo "hydrate: $pkg_dir: worktree ready at $sha"
}

# Optional first arg: package directory to hydrate (relative or absolute).
# No arg = hydrate all packages under libs/ and pkgs/.
target_pkg="${1:-}"

if [ -n "$target_pkg" ]; then
    # Normalize: strip any leading ./ and trailing /
    target_pkg="${target_pkg#./}"
    target_pkg="${target_pkg%/}"
    if [ ! -f "$target_pkg/versions.toml" ]; then
        echo "hydrate: $target_pkg: no versions.toml at this path" >&2
        exit 1
    fi
    pkg_dirs=("$target_pkg")
else
    pkg_dirs=()
    while IFS= read -r line; do
        pkg_dirs+=("$line")
    done < <(find . -type d \( -path './libs*' -o -path './pkgs*' \) -mindepth 2 -maxdepth 3 2>/dev/null | sed 's|^\./||' | sort)
fi

for pkg_dir in "${pkg_dirs[@]}"; do
    toml="$pkg_dir/versions.toml"
    if [ ! -f "$toml" ]; then
        continue
    fi

    source_type=$(get "$toml" "type")
    case "$source_type" in
        tarball) hydrate_tarball "$pkg_dir" || true ;;
        git)     hydrate_git "$pkg_dir" || true ;;
        *)       echo "hydrate: $pkg_dir: unknown source.type '$source_type'" >&2 ;;
    esac
done

echo "hydrate: done"
