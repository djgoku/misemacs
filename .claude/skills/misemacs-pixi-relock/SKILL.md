---
name: misemacs-pixi-relock
description: This skill should be used when changing a misemacs version's C dependencies, such as relocking versions/<v>/pixi.lock, editing a versions/<v>/pixi.toml, bumping the enchant recipe in djgoku/enchant-feedstock, or debugging a pixi update or pixi lock that fails to solve.
---

# Relocking misemacs pixi environments

Each `versions/<v>/` holds a pixi workspace whose lock pins the full conda-forge closure for that Emacs version. enchant is the exception: pixi-build compiles it from the `recipe/` directory of the `misemacs-recipe` branch of `djgoku/enchant-feedstock`.

## State the release impact first

`versions/<v>/pixi.toml` and `pixi.lock` feed that version's fingerprint, so any change to either file rebuilds and releases that channel on the next daily run. A change to every version releases every channel.

- Keep each dependency change separate and as small as the goal allows.
- Say which channels will release before you make the change.
- Run a broad `pixi update` only when the user asks for one. The update-deps sweep proposes one each night as a `deps/pixi` PR; merging that PR is the ask. Review it as a full update that releases every channel, and fix a failed or regressed sweep run with the rest of this skill.

## Read a solver failure

Filter the repeated lines so the root cause shows:

```sh
mise exec -- pixi update --dry-run --manifest-path versions/<v>/pixi.toml 2>&1 \
  | grep -v "conflicts with the versions reported above"
```

## Pin the source-built package in its recipe

pixi-build does not apply conda-forge's global pinning. An unversioned host dependency in the recipe resolves to its newest build, and that build's run_exports set a floor in every consumer. A pin under `[dependencies]` in `pixi.toml` cannot override that floor.

- Pin the dependency in the recipe's `requirements.host`, with a comment that says when to lift it.
- To see what conda-forge CI would have used, read the feedstock's `.ci_support/*.yaml`.
- Untested alternative: a `[workspace.build-variants]` entry for that package in each `pixi.toml`.

## Test a recipe change before you push it

1. Copy `versions/<v>/pixi.toml` and `pixi.lock` to a scratch directory.
2. Replace the enchant line with `enchant = { path = "<feedstock checkout>/recipe" }`.
3. Run `mise exec -- pixi update --dry-run --manifest-path <scratch>/pixi.toml` to check the solve.
4. Run `mise exec -- pixi install --manifest-path <scratch>/pixi.toml` to build it.
5. Check the result: `<scratch>/.pixi/envs/default/bin/enchant-lsmod-2` lists hunspell and AppleSpell, and `otool -L <scratch>/.pixi/envs/default/lib/libenchant-2.dylib` shows the expected glib.

## Relock one package

Run `mise exec -- pixi update --manifest-path versions/<v>/pixi.toml enchant` with `--dry-run` first, and read every row it lists.

- A row other than enchant usually comes from the build compiler's run_exports. For example, clang 23 raises `libcxx` to 23.
- Hold the compiler with `c_compiler_version` and `cxx_compiler_version` under `[workspace.build-variants]`. Raise them on purpose, together with a full update.
- To see what a source package depends on, read its `- conda_source: enchant` entry in `pixi.lock`: `depends:`, `variants:`, and `build_packages:`.

## Prove what changed

`pixi.lock` is marked `-diff`, so `git diff --stat` shows `Bin` or hundreds of lines even for a one-package relock. Compare the environment package lists instead:

```sh
env_pkgs() { awk '/^packages:/{exit} /- conda(_source)?:/{sub(/^ +- /,""); print}' | sort; }
diff <(git show HEAD:versions/<v>/pixi.lock | env_pkgs) <(env_pkgs < versions/<v>/pixi.lock)
```

## Keep locked commits reachable

The lock pins enchant as `branch=misemacs-recipe#<sha>`. Rebasing or force-pushing that branch leaves the locked commit on no branch, and `pixi install --locked` fails once GitHub garbage-collects it.

- Before you rewrite the branch, relock every version to the new head, or push a backup ref for the old commit.
- To check that a commit can still be fetched: `git init -q <scratch> && git -C <scratch> fetch --depth 1 https://github.com/djgoku/enchant-feedstock <sha>`.

## Verify

- Run `mise run build <v>`, `stage-enchant <v>`, `relocate <v>`, and `cleanroom <v>` for each version you changed.
- PR CI builds every version in dry-run mode and uploads each tarball as `dryrun-<v>-macos-arm64`. To check one locally, download it with `gh run download <run> -n dryrun-<v>-macos-arm64`, copy its `Emacs.app` to `build/<v>/`, and run `mise run cleanroom <v>`.
- Run `mise run test`. `version_layout_test.exs` checks that each version's inputs exist and that emacs-30's lock stays on tree-sitter 0.25.
