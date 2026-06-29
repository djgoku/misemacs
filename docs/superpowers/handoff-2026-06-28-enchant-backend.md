# Handoff — misemacs bundled-enchant: backend debug + finalize

*Written 2026-06-28 to continue in a fresh session (the originating session's context got deep). Everything referenced here is persistent — repo, committed docs, and auto-loaded memory. The prior session's `scratchpad/` is gone; recreate the spike env with the commands below.*

## TL;DR

Continue the "bundle enchant into every misemacs `Emacs.app`" feature. The payload **machinery is built and verified** (Tasks 1–5); a real-artifact spike **validated the plumbing** but surfaced two things to fix before finalizing:
1. **Drop the too-strict build-prefix `leak_check`** (clear fix).
2. **Root-cause an applespell/dictionary segfault**, then implement the backend as **applespell default + hunspell as a working option (ship an `en_US` hunspell dict)**.

Then finish Task 6 (wire it in + real cleanroom e2e) and Task 7 (docs). Use the superpowers workflow (the feature went brainstorming → spec → plan → subagent-driven-development); keep verifying empirically (spike over guess).

## State (all persistent)

- **Repo:** `/Users/admin/dev/github/djgoku/misemacs`. Work continues on branch **`enchant-task6`** (branched off `enchant`; both at commit `263fefa`). `enchant` holds the verified Tasks 1–5 increment.
- **Spec:** `docs/superpowers/specs/2026-06-25-bundled-enchant-payload-design.md`
- **Plan:** `docs/superpowers/plans/2026-06-28-bundled-enchant-payload.md` — its top **"Review revisions (Codex 2026-06-28)" R1–R12 block is authoritative**.
- **Memory (auto-loads):** `misemacs-enchant-payload-decisions.md` (full decision log + spike results), `enchant-feedstock-facts.md` (recipe/jinx facts), `spike-over-guess.md` (work style).
- **SDD ledger:** `.superpowers/sdd/progress.md` (gitignored) — per-task status + accumulated findings.
- **Implemented (full suite 117 passing, lint clean):** `orchestrator/lib/orchestrator/payload/enchant.ex` (+ `test/orchestrator/payload_enchant_test.exs`), per-file `sign_file`/`verify_file` in `macho/tool.ex`+`otool.ex`, `relocate.ex` integration (excludes `Contents/Resources/enchant/**`, relocates+per-file-signs the payload before the deep sign, runs both gates), `naming.ex` + `aqua/registry.yaml` PATH exposure. Run tests: `mise run test` (add `--include macos` via `mise exec -- sh -c 'cd orchestrator && mix test --include macos'`).

## Toolchain note

`pixi 0.70.2` is installed via mise, and the mise plugins `pixi-env` + `vfox-pixi` are installed (they were missing originally — `mise plugins install pixi-env https://github.com/esteve/mise-env-pixi` and `… vfox-pixi https://github.com/esteve/mise-backend-pixi` if a clean machine). Run pixi as `mise exec -- pixi …`. (`mise.lock` was bumped to erlang 29.0.2 in commit `a1fb277`.)

## Phase 0 is SOLVED — git-source via pixi-build (no channel publish needed)

Validated: pixi builds the **real feedstock enchant** (both providers + the `dladdr` self-relocation patch) straight from the git branch. Recreate the env in a fresh session:

```sh
D=$(mktemp -d)/ench && mkdir -p "$D" && cd "$D"
cat > pixi.toml <<'EOF'
[workspace]
name = "ench"
channels = ["conda-forge"]
platforms = ["osx-arm64"]
preview = ["pixi-build"]
[dependencies]
enchant = { git = "https://github.com/djgoku/enchant-feedstock", branch = "misemacs-recipe", subdirectory = "recipe" }
EOF
mise exec -- pixi install --manifest-path pixi.toml      # builds enchant (~minutes)
P="$D/.pixi/envs/default"                                 # the built enchant prefix
ls "$P/lib/enchant-2/"   # => enchant_applespell.so  enchant_hunspell.so
"$P/bin/enchant-lsmod-2" # => hunspell (Hunspell Provider) / AppleSpell (AppleSpell Provider)
```

`pixi.lock` pins the git commit (reproducible; `pixi update` re-resolves the branch). This replaces the spec's "publish to a channel" Phase 0 and the plan's "build inline" fallback — reconcile both to git-source. Tradeoff: source build re-runs per fresh env (CI cost); build-inline remains the fallback if that bites.

## How to stage the real enchant for testing (the spike harness)

The actual `Orchestrator.Payload.Enchant` code stages from a conda prefix into a mock bundle. From the repo:

```sh
APP=$(mktemp -d)/Emacs.app && mkdir -p "$APP/Contents/Resources"
cd /Users/admin/dev/github/djgoku/misemacs/orchestrator
mise exec -- mix run -e '
  [app, prefix] = System.argv()
  :ok = Orchestrator.Payload.Enchant.stage_copy(app, prefix)
  :ok = Orchestrator.Payload.Enchant.relocate(app)
  IO.inspect(Orchestrator.Payload.Enchant.verify(app, prefix), label: "VERIFY")
' "$APP" "$P"     # $P = the built enchant prefix from above
ENCH="$APP/Contents/Resources/enchant"   # staged, relocated, per-file-signed payload
```
Cleanroom proof = move `$P` aside (`mv "$P" "$P.aside"`), then run `"$ENCH/bin/enchant-lsmod-2"` — it lists both providers via the in-bundle `dladdr` self-relocation. CONFIRMED working.

## Finding 1 — drop the too-strict `leak_check` (clear fix)

`Orchestrator.Payload.Enchant.verify/3` runs a build-prefix `leak_check` (greps every staged file for the conda prefix string). Real conda dylibs (libenchant, providers, glib/gio/intl) bake the install prefix into **inert data-section strings** that `install_name_tool` can't strip — so `verify` false-flagged 6 libs as a "leak." The self-containment that matters (load commands) is already proven by the macho gate + the functional cleanroom run (both pass), and `dladdr` overrides any compiled-in prefix at runtime.

**Task:** remove (or tightly scope) `leak_check` from `verify/3`. Keep the macho self-containment gate + per-file `codesign --verify --strict`. Reconcile: spec §14, the plan's R9 / Task-3 e2e leak assertions, and Codex-D's `strings|grep` recommendation.

## Finding 2 — applespell/dict segfault (OPTION A: debug, then fix the backend)

Observed with the staged real enchant in the cleanroom:
- `enchant_broker_dict_exists("en_US")` returned **0** (applespell did not claim `en_US`).
- `printf 'helllo\n' | "$ENCH/bin/enchant-2" -l -d en_US` → **Segmentation fault** (most likely the **dictionary-less hunspell** fallback crashing when no provider supplies `en_US`).
- For contrast: `enchant_broker_init()` + `enchant_broker_dict_exists` (the jinx path) ran fine; `enchant-lsmod-2` lists both providers. So libenchant + provider loading work — it's the **dict-request path** that crashes.

**Debug steps (root-cause first):**
1. Reproduce with the staged bundle (above). Get an `lldb`/crash backtrace: `lldb -b -o run -o bt -- "$ENCH/bin/enchant-2" -l -d en_US <<<'helllo'` — identify which provider/frame segfaults.
2. Narrow the trigger: `-d en` vs `-d en_US`; no `-d`; applespell-only ordering vs hunspell-only; env present vs aside; with vs without a hunspell `en_US` dict present.
3. Investigate `dict_exists("en_US")=0`: read enchant's applespell provider source — is AppleSpell (NSSpellChecker) actually usable from a headless/CLI process, or only "present"? Does `request_dict` succeed even when `dict_exists` returns 0? Determine whether applespell can genuinely spell-check `en_US`.

**Backend decision (user-confirmed): applespell default, hunspell a working option.**
- Keep `*:applespell,hunspell` ordering (applespell first). This is the design's `ordering_contents/0`.
- **Ship a real `en_US` hunspell dict** so hunspell is genuinely usable when selected — and this very likely **fixes the segfault** (the crash is the dict-less fallback). This updates **Decision C** (was "zero bundled dictionaries").
  - Find the path enchant's hunspell provider searches for dicts relative to the prefix (check enchant source / `ENCHANT_CONFIG_DIR` / `<prefix>/share/enchant/hunspell` etc.) and stage the dict there.
  - Pick a permissively-licensed `en_US` hunspell `.aff/.dic` (e.g. the SCOWL/`en_US` dict shipped with LibreOffice/Hunspell — **audit the license** and record it in the spec).
- Confirm after the fix: `enchant-2 -d en_US` no longer segfaults; applespell remains the default; a user can switch to hunspell.

## After the debug + backend fix — finish the feature

1. **Reconcile docs:** spec — Decision C (applespell default + bundled `en_US` hunspell dict), §13 (ordering + dict path + license), §14 (drop leak_check), §6/§2 (Phase 0 = git-source), §15 (close O6/O7/O8 as resolved). Plan — Task 6 (git-source dep + dict staging), R9/R10/R12, drop leak_check.
2. **Task 6** (now unblocked): add `enchant = { git=…, branch="misemacs-recipe", subdirectory="recipe" }` + `preview = ["pixi-build"]` to **both** `versions/master/pixi.toml` and `versions/emacs-31/pixi.toml`; re-lock; ensure the dict is staged; `pipeline/stage-enchant` (copy-only `mix payload.enchant`, runs after build, before `mise run relocate` which now relocates+signs+gates the payload — see plan R7); extend `mise run cleanroom` (real `enchant-lsmod-2` + a working `enchant-2 -d en_US` + jinx e2e + symlinked launch). A full validation needs a real Emacs build (`mise run build` ~15–20 min) → relocate → stage-enchant → cleanroom.
3. **Task 7:** O1 (real `site-lisp` path from the build), O2 (pkg-config shim chosen), O5 (`site-start` opt-out), validation-log + the spec reconcile above. Plus the small follow-ups: a comment on the `relocate.ex:run/3` ⇄ `conda-prefix-lib.txt` coupling; the `.pc`/shim version-pin reconcile.
4. **Execution:** continue with `superpowers:subagent-driven-development` (or `executing-plans`); update the SDD ledger. When done, `superpowers:finishing-a-development-branch`. Note: repo currently has no `main` branch and no remote, so "finish" = keep the branch / establish a baseline as the user directs.

## Guardrails

macOS arm64 only. Verify empirically (spike over guess) — don't take a claim (even a reviewer's) as fact when it's checkable. Commit only when asked; end commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. The user's full preferences are in auto-loaded memory.
