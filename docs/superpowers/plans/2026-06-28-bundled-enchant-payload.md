# Bundled enchant payload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bundle `enchant` (spell-check library + providers) inside every misemacs `Emacs.app` as a self-contained, relocated sub-prefix, so **jinx compiles and runs on a clean macOS machine** with no Homebrew/system enchant.

**Architecture:** enchant is a **companion payload** staged into `Emacs.app/Contents/Resources/enchant/` and relocated by a new `Orchestrator.Payload.Enchant` seam that **reuses the existing `Orchestrator.Macho` primitives** with bundle-root `enchant/lib` (instead of `Contents/Frameworks`). It follows the orchestrator's pure-core + IO-adapter pattern: pure planning functions (generated file contents, gate evaluation) are fixture-tested everywhere; the stage/relocate/verify IO is `@tag :macos`-tested against **clang-built synthetic fixtures** (no published artifact needed). The Emacs relocator is changed in exactly one bounded way — it **excludes `Contents/Resources/enchant/**`** from its Frameworks closure walk; the payload owns its own subtree, **per-file signs** it (spike-1: `codesign --deep` skips `Resources/`), and runs its own gate. jinx finds the bundle via a `${pcfiledir}`-relocatable `.pc` + a scoped `pkg-config` shim emitting `-Wl,-rpath`; staleness on Emacs update is repaired in place with `install_name_tool -rpath` (spike-3).

**Tech Stack:** Elixir 1.20 / ExUnit (`orchestrator/`); `otool`/`install_name_tool`/`codesign` shelled via `System.cmd` behind `Orchestrator.Macho.Tool`; clang (synthetic Mach-O test fixtures); bash pipeline stage; pixi/conda (provenance) + `pixi.lock` (pin); mise (tasks); aqua registry (PATH exposure).

## Global Constraints

- **Platform:** macOS `arm64` only (v1).
- **enchant version:** `2.8.2`, from the **feedstock** channel (assumed prefix.dev `djgoku`), **pinned in `pixi.lock`** — same reproducibility contract as gnutls/libxml2/tree-sitter.
- **Backend:** **applespell default, zero bundled dictionaries**; hunspell present (dictionary-less). Ship ordering `*:applespell,hunspell` at `enchant/share/enchant-2/enchant.ordering` (spike-C: NOT `share/enchant/`).
- **Layout (load-bearing — feedstock `dladdr` self-relocation, spec §5.1):** `enchant/lib/libenchant-2.2.dylib` + `enchant/lib/enchant-2/enchant_*.so`. The `/lib/` component is required; **never flatten enchant into `Contents/Frameworks`** (spike-D).
- **Signing:** `Payload.Enchant` **signs and verifies each enchant Mach-O individually** (`codesign --force --sign -` then `--verify --strict`); the app-level `--deep` does NOT reach `Resources/` (spike-1, S1).
- **Staging includes the unversioned `libenchant-2.dylib` symlink** or jinx's `cc … -lenchant-2` fails (spike-A).
- **Pattern:** pure logic has no IO and is fixture-tested; IO is behind `Orchestrator.Macho.Tool` (injectable). Modules carry `@moduledoc`/`@type`/`@spec`/`@doc`. `mise run test` + `mise run lint` (`mix format --check-formatted`, `--warnings-as-errors`) green. **Commit after each task.**

## Precondition: Phase 0 (external, feedstock repo)

The feedstock branch `djgoku/enchant-feedstock@misemacs-recipe` must be **built (rattler-build) and published to a conda channel** so pixi can resolve `enchant 2.8.2`. This is feedstock-repo work (needs channel credentials) — **not** part of this plan.

- **Tasks 1–5 do NOT need it** — they build + test the entire Elixir seam against clang-built synthetic Mach-O fixtures (proven by the facet-A spike). Implement and merge them now.
- **Task 6 is Phase-0-gated** — it adds the pixi dep (which can only resolve once published) and the real build/cleanroom e2e. It is clearly marked; do not start it until Phase 0 is done.

## Review revisions (Codex 2026-06-28) — AUTHORITATIVE, apply throughout

A Codex review found real bugs in the task code below. **These corrections supersede the
as-written task code wherever they conflict.** (Finding #5 — the `~S` heredoc backslashes in
`site_start_el/0` — was a **false positive**: `~S` emits `\\(`/`\\)` literally, which Emacs's
string reader turns into the regexp `\(`/`\)`; leave them as written.)

**R1 (Task 2, #1) — keep the existing test double compiling.** Adding `sign_file`/`verify_file`
to `Macho.Tool` turns `Orchestrator.RelocateTest.TamperAfterSignTool` (relocate_test.exs:7) into
a behaviour with missing callbacks → `--warnings-as-errors` fails. In Task 2, also add to that
double: `defdelegate sign_file(p), to: Otool` and `defdelegate verify_file(p), to: Otool`.

**R2 (Task 3, #2) — guard `set_id` to dylibs.** Providers are `MH_BUNDLE`, CLIs are executables;
`install_name_tool -id` (which `Otool.set_id` asserts exit 0) errors on a non-dylib. In
`relocate/2`: `if tool.id(m), do: tool.set_id(m, "@rpath/" <> Path.basename(m))`.

**R3 (Task 3, #3/#14) — CLIs must stay executable.** `cp!/2` forces `0644`; `pipeline/package`
checks `-x`. Add `defp cp_exec!(from, to), do: (File.cp!(from, to); File.chmod!(to, 0o755))` and
copy `enchant-2`/`enchant-lsmod-2` with `cp_exec!`, not `cp!`.

**R4 (Task 3, #4) — unversioned symlink: idempotent + never scanned as Mach-O.** Create it as
`_ = File.rm(Path.join(lib, "libenchant-2.dylib")); File.ln_s!("libenchant-2.2.dylib", Path.join(lib, "libenchant-2.dylib"))`.
And make `machos/2` skip symlinks (else it follows the symlink and double-edits the versioned
dylib) by filtering with `File.lstat/1`:
```elixir
defp machos(ench, tool) do
  Path.join(ench, "**") |> Path.wildcard()
  |> Enum.filter(fn f -> match?({:ok, %File.Stat{type: :regular}}, File.lstat(f)) end)
  |> Enum.filter(&tool.macho?/1)
end
```

**R5 (Task 3, #6) — stage owns its dirs.** Add `File.mkdir_p!(Path.join(app, "Contents/Resources/site-lisp"))`
before writing `site-start.el`; don't rely on the test creating it. (O1 confirms the real path in Task 7.)

**R6 (Task 3 split, #7/#9) — separate copy from relocate.** Public API is exactly: `stage_copy(app, conda_prefix)`
(copy + closure + generated files; **no** install_name edits), `relocate(app)` (install_name/rpath
normalize in `enchant/lib` + per-file sign), `verify(app, conda_prefix)` (gate). `tool` is a defaulted
last arg on each (`stage_copy/3`, `relocate/2`, `verify/3` are the injectable forms). Update the file-table
arities and the spec's §8 API note to match.

**R7 (Task 4 + Task 6, #9/#10) — one sealed sequence; `mix relocate` owns both gates.**
- Pipeline order: `build → stage-enchant (copy only) → relocate → package`.
- `pipeline/stage-enchant` → `mix payload.enchant`, which now calls **only** `Enchant.stage_copy/2`.
- `Orchestrator.Relocate.run/3`: after the Frameworks closure is built+rewritten and **before**
  `tool.sign_bundle(app)`, do `if File.dir?(ench), do: Enchant.relocate(app, tool)` (per-file signs the
  payload). Then `tool.sign_bundle(app)` deep-signs/seals the whole bundle incl. the payload. After
  `verify_bundle`, run **both** gates: `Enchant.verify(app, conda_prefix, tool)` (where `conda_prefix` =
  `build_libdir` minus the trailing `/lib`) **and** the existing `gate(app, fw, tool)`. `package` stays
  check-only — nothing mutates the bundle after the deep sign (#9).

**R8 (Task 4 test, #11/#12) — make the exclusion test real.** Build the enchant fixture dylib with a
**foreign dep in `buildlib`** and assert that dep is NOT copied into `Contents/Frameworks` (proves the walk
skipped the subtree). Add a pure fake-tool unit test that `machos/2` rejects a path under `Resources/enchant/`.

**R9 (Task 3 e2e, #8/#13) — assert what matters.** Add: each staged CLI is executable
(`Bitwise.band(File.stat!(p).mode, 0o111) != 0`); each provider is signed (`verify_file` → `:ok`), has no
foreign deps/rpaths, and no `@rpath` dep on another provider. (Provider discovery / applespell / dladdr
stay Task-6, real-artifact.)

**R10 (Task 6, #15) — feedstock channel first.** `channels = ["<feedstock-channel>", "conda-forge"]`, and
assert the resolved `enchant` URL in `pixi.lock` is the feedstock channel (not conda-forge) before proceeding.

**R11 (Task 6, #16) — pin jinx + probe.** Pin a specific jinx version in the cleanroom e2e (not ELPA-latest)
and assert `(fboundp 'jinx--load-module)` with a clear O4 message before using it.

**R12 (Task 7, #17) — make open items hard gates.** O6 (applespell in `enchant-lsmod-2`) and O9 (symlinked
launch) are **pass/fail Task-6 gates**, not "record if settled". O7: the feedstock channel URL must be filled
before the re-lock. S1 is regression-covered by the R9 `verify_file` assertions.

## Backend + Phase-0 + leak_check revisions (2026-06-28, real-artifact debug) — AUTHORITATIVE

A focused debug spike (git-source-built **real** feedstock enchant staged + lldb'd in the cleanroom)
supersedes three earlier assumptions. Apply throughout:

- **R13 — Phase 0 = git-source via pixi-build (no channel publish).** Everywhere the plan/spec says
  "publish the feedstock to a conda channel" / `<feedstock-channel>`, use instead, in **both**
  `versions/<v>/pixi.toml`: `[workspace] preview = ["pixi-build"]` and
  `enchant = { git = "https://github.com/djgoku/enchant-feedstock", branch = "misemacs-recipe", subdirectory = "recipe" }`.
  `pixi.lock` pins the git commit (the reproducibility pin). R10's "assert URL is the feedstock channel"
  becomes "assert the locked enchant source is the feedstock git repo + commit". No prefix.dev/anaconda account.
- **R14 — `stage_copy` must stage `share/enchant-2/AppleSpell.config`; no hunspell dict is bundled.**
  Root cause of the en_US SEGFAULT + `dict_exists("en_US")=0` (handoff Finding 2) is that `stage_copy` dropped
  the feedstock's `AppleSpell.config` (applespell's locale map) — NOT a dict-less hunspell crash. Fix: copy
  `AppleSpell.config` from the prefix (guarded by `File.exists?`); raise if the applespell provider is staged
  without it. Decision C is "applespell default, zero bundled dictionaries; hunspell is bring-your-own" (spec
  §13) — no `en_US.aff`/`.dic` ship; the e2e asserts `AppleSpell.config` is staged and `share/hunspell/` is
  **not**. **DONE on branch.** Residual upstream applespell bare-`en` crash → feedstock-patch follow-up
  (region tags are safe).
- **R15 — drop the build-prefix `leak_check`.** Real conda dylibs bake the install prefix into inert
  data-section strings → `verify/3`'s `strings`-grep false-flagged 6 relocated libs. Removed from `verify/3`
  (`conda_prefix` arg kept for signature stability, unused) and the leak failure test removed. **This also
  voids the Task-6 cleanroom `strings | grep '/(envs|\.pixi)/'` step (R15) — do not add it.** The macho gate +
  per-file `codesign --verify --strict` + the functional cleanroom run are the real self-containment proof.
  Supersedes spec §14's leak bullet, the R9 leak mention, and Codex-D's `strings|grep` recommendation.

## File Structure

| Path | New? | Responsibility |
|---|---|---|
| `orchestrator/lib/orchestrator/payload/enchant.ex` | create | The enchant payload seam: pure generated-file contents (`pc_contents/0`, `pkgconfig_shim/0`, `site_start_el/0`, `ordering_contents/0`) + IO runner (`stage/3` copy+relocate+per-file-sign into `enchant/lib`; `verify/2` otool self-containment + per-file codesign verify + build-prefix leak check). Reuses `Orchestrator.Macho`. |
| `orchestrator/lib/mix/tasks/payload.enchant.ex` | create | `mix payload.enchant <app> <conda_prefix>` → `Payload.Enchant.stage/3` then `verify/2`. |
| `orchestrator/lib/orchestrator/macho/tool.ex` | modify | Add `@callback sign_file/1`, `@callback verify_file/1` (per-file codesign). |
| `orchestrator/lib/orchestrator/macho/otool.ex` | modify | Implement `sign_file/1` (`codesign --force --sign -`), `verify_file/1` (`codesign --verify --strict`). |
| `orchestrator/lib/orchestrator/relocate.ex` | modify | Exclude `Contents/Resources/enchant/**` from `machos/2`; call `Payload.Enchant.relocate/2` before `sign_bundle`; run the payload gate alongside the Emacs gate. |
| `orchestrator/lib/orchestrator/naming.ex` | modify | Add `enchant-2` + `enchant-lsmod-2` (under `Resources/enchant/bin/`) to `bundle_binaries/0`. |
| `aqua/registry.yaml` | modify | Add `enchant-2` + `enchant-lsmod-2` `files:` entries to **both** packages. |
| `orchestrator/test/orchestrator/payload_enchant_test.exs` | create | Pure tests (everywhere) for the generated contents + a `@tag :macos` end-to-end fixture test (synthetic enchant → stage → relocate → per-file sign → verify → compile a jinx-stub via the shim → dlopen). |
| `orchestrator/test/orchestrator/relocate_test.exs` | modify | Add a case: a Mach-O staged under `Contents/Resources/enchant/` is excluded from Frameworks and left to the payload gate. |
| `orchestrator/test/orchestrator/registry_contract_test.exs` | modify | Bind the two new registry `files:` entries to `bundle_binaries/0`. |
| `versions/master/pixi.toml`, `versions/emacs-31/pixi.toml`, `versions/*/pixi.lock` | modify | **(Task 6, Phase-0-gated)** add `enchant = "2.8.2"` + channel; re-lock. |
| `pipeline/stage-enchant` | create | **(Task 6)** bash wrapper: `mix payload.enchant build/<v>/Emacs.app "$(cat build/<v>/conda-prefix-lib.txt | sed s/.lib//)"`. |
| `mise.toml` | modify | **(Task 6)** add `[tasks.stage-enchant]`; extend `[tasks.cleanroom]` with the enchant smoke + leak gate + symlinked-launch (O9). |
| `docs/superpowers/validation-log.md`, `docs/superpowers/specs/2026-06-25-bundled-enchant-payload-design.md` | modify | **(Task 7)** record findings; resolve O1/O2/O5. |

**Conventions:** tests `use ExUnit.Case`; `@tag :macos` excluded off Darwin by `test_helper.exs`; clang builds fixture dylibs (`-install_name @rpath/<base>`, `-Wl,-headerpad_max_install_names`); commit after each task.

---

## Task 1: `Orchestrator.Payload.Enchant` — pure generated contents (TDD, runs everywhere)

The pure heart: the exact bytes of the four generated files. No IO — fixture-tested on every platform.

**Files:**
- Create: `orchestrator/lib/orchestrator/payload/enchant.ex` (pure functions only this task)
- Test: `orchestrator/test/orchestrator/payload_enchant_test.exs`

**Interfaces — Produces:**
- `Orchestrator.Payload.Enchant.pc_contents() :: String.t()`
- `Orchestrator.Payload.Enchant.pkgconfig_shim() :: String.t()`
- `Orchestrator.Payload.Enchant.site_start_el() :: String.t()`
- `Orchestrator.Payload.Enchant.ordering_contents() :: String.t()`

- [ ] **Step 1: Write the failing pure tests** — `orchestrator/test/orchestrator/payload_enchant_test.exs`:

```elixir
defmodule Orchestrator.Payload.EnchantTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Payload.Enchant

  test "pc_contents is ${pcfiledir}-relocatable and injects an rpath" do
    pc = Enchant.pc_contents()
    assert pc =~ "prefix=${pcfiledir}/../.."
    assert pc =~ "libdir=${prefix}/lib"
    assert pc =~ "includedir=${prefix}/include"
    assert pc =~ "Libs: -L${libdir} -lenchant-2 -Wl,-rpath,${libdir}"
    assert pc =~ "Cflags: -I${includedir}/enchant-2"
    refute pc =~ ~r{/(private|Users|opt|envs)/}, "no absolute build path may leak into the .pc"
  end

  test "pkgconfig_shim self-locates, emits rpath, and refuses non-enchant-2 queries" do
    sh = Enchant.pkgconfig_shim()
    assert sh =~ "#!/bin/sh"
    assert sh =~ ~s{prefix=$(cd "$(dirname "$0")/.." && pwd)}
    assert sh =~ "-I$prefix/include/enchant-2"
    assert sh =~ "-L$prefix/lib -lenchant-2 -Wl,-rpath,$prefix/lib"
    # O2: must not blindly answer for arbitrary packages
    assert sh =~ "enchant-2"
    assert sh =~ "exit 1"
  end

  test "site_start_el is discovery-only, jinx-scoped, and self-heals stale rpaths" do
    el = Enchant.site_start_el()
    assert el =~ "with-eval-after-load 'jinx"
    assert el =~ "fboundp 'jinx--load-module"
    assert el =~ "advice-add 'jinx--load-module"
    assert el =~ "install_name_tool"          # spike-3 rpath-patch self-heal
    assert el =~ "misemacs-enchant-disable"   # opt-out (O5)
    refute el =~ "ispell-program-name", "discovery-only: must not set policy"
    refute el =~ "DYLD_FALLBACK_LIBRARY_PATH", "spike-2: dead, must not appear"
  end

  test "ordering_contents makes applespell default" do
    assert Enchant.ordering_contents() == "*:applespell,hunspell\n"
  end
end
```

- [ ] **Step 2: Run it and watch it fail**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/payload_enchant_test.exs'`
Expected: FAIL — `Orchestrator.Payload.Enchant` undefined.

- [ ] **Step 3: Write the pure module** — `orchestrator/lib/orchestrator/payload/enchant.ex` (this task: the four generators + module doc; the IO runner is Task 3):

```elixir
defmodule Orchestrator.Payload.Enchant do
  @moduledoc """
  The bundled-enchant companion payload. enchant is staged as a self-contained sub-prefix at
  `Emacs.app/Contents/Resources/enchant/` and relocated with **bundle-root = `enchant/lib`**
  (NOT `Contents/Frameworks`), because the feedstock's `dladdr` self-relocation requires
  `<prefix>/lib/libenchant-2.2.dylib` + `<prefix>/lib/enchant-2/` (design §5.1/§7).

  Pure here: the exact bytes of the four generated files. The copy/relocate/sign IO is the
  `stage/3` + `verify/2` runner (reuses `Orchestrator.Macho`, IO via `Orchestrator.Macho.Tool`).
  """
  alias Orchestrator.Macho

  @enchant_rel "Contents/Resources/enchant"
  @doc "Sub-prefix dir, relative to the app bundle root."
  @spec enchant_rel() :: String.t()
  def enchant_rel, do: @enchant_rel

  @doc "Relocatable `enchant-2.pc` (design §9): `${pcfiledir}`-relative, rpath injected into Libs."
  @spec pc_contents() :: String.t()
  def pc_contents do
    """
    prefix=${pcfiledir}/../..
    exec_prefix=${prefix}
    libdir=${prefix}/lib
    includedir=${prefix}/include

    Name: libenchant
    Description: A spell checking library
    Version: 2.8.2
    Libs: -L${libdir} -lenchant-2 -Wl,-rpath,${libdir}
    Cflags: -I${includedir}/enchant-2
    """
  end

  @doc """
  Minimal self-locating `pkg-config` shim (design §10). Answers ONLY `enchant-2` (O2: refuses
  anything else so it can't shadow a real pkg-config) and emits `-Wl,-rpath` so jinx's compiled
  module resolves libenchant from the bundle. Scoped to jinx's compile by `site_start_el/0`.
  """
  @spec pkgconfig_shim() :: String.t()
  def pkgconfig_shim do
    """
    #!/bin/sh
    # misemacs bundled pkg-config shim — answers `enchant-2` only (scoped to jinx via site-start).
    case " $* " in
      *" enchant-2 "*) : ;;
      *) echo "misemacs pkg-config shim: only 'enchant-2' is supported" >&2; exit 1 ;;
    esac
    prefix=$(cd "$(dirname "$0")/.." && pwd)
    out=""
    for a in "$@"; do
      case "$a" in
        --cflags) out="$out -I$prefix/include/enchant-2" ;;
        --libs)   out="$out -L$prefix/lib -lenchant-2 -Wl,-rpath,$prefix/lib" ;;
      esac
    done
    echo $out
    """
  end

  @doc """
  `site-start.el` (design §11). Discovery-only — adds nothing unless jinx loads, sets no policy.
  (1) scopes the `pkg-config` shim onto `exec-path` for jinx's module compile;
  (2) self-heals a stale embedded enchant rpath in place via `install_name_tool -rpath`
      (spike-3: recompile-free, arm64 auto re-signs) after an Emacs update moved the app path.
  Opt out with `(setq misemacs-enchant-disable t)` or `emacs -Q` / `--no-site-file`.
  """
  @spec site_start_el() :: String.t()
  def site_start_el do
    ~S"""
    ;;; site-start.el --- misemacs: compile jinx against the bundled enchant  -*- lexical-binding: t; -*-
    (defun misemacs--enchant-rpath-fix (mod lib)
      "Repoint any stale enchant LC_RPATH in MOD to LIB (install_name_tool re-signs on arm64)."
      (with-temp-buffer
        (when (eq 0 (call-process "otool" nil t nil "-l" mod))
          (goto-char (point-min))
          (while (re-search-forward "path \\(.*/Contents/Resources/enchant/lib\\) (offset" nil t)
            (let ((old (match-string 1)))
              (unless (string= old lib)
                (call-process "install_name_tool" nil nil nil "-rpath" old lib mod)))))))
    (unless (bound-and-true-p misemacs-enchant-disable)
      (let* ((app (expand-file-name "../../.." (file-name-directory load-file-name)))
             (ench (expand-file-name "Contents/Resources/enchant" app))
             (bin (expand-file-name "bin" ench))
             (lib (expand-file-name "lib" ench)))
        (with-eval-after-load 'jinx
          (when (fboundp 'jinx--load-module)
            (advice-add 'jinx--load-module :around
                        (lambda (orig &rest args)
                          (let ((exec-path (cons bin exec-path))) (apply orig args)))))
          (dolist (dir load-path)
            (dolist (mod (file-expand-wildcards (expand-file-name "jinx-mod*.so" dir)))
              (ignore-errors (misemacs--enchant-rpath-fix mod lib)))))))
    """
  end

  @doc "enchant.ordering making applespell the default backend (design §13, spike-C)."
  @spec ordering_contents() :: String.t()
  def ordering_contents, do: "*:applespell,hunspell\n"

  # IO runner (stage/3, verify/2) is added in Task 3.
  @doc false
  def __macho__, do: Macho
end
```

- [ ] **Step 4: Run the pure tests to verify they pass**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/payload_enchant_test.exs'`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Format + full suite + commit**
Run: `mise run fmt && mise run test && mise run lint`
Expected: all green, no warnings.

```bash
git add orchestrator/lib/orchestrator/payload/enchant.ex orchestrator/test/orchestrator/payload_enchant_test.exs
git commit -m "feat(enchant): Orchestrator.Payload.Enchant pure generated contents (.pc/shim/site-start/ordering)"
```

---

## Task 2: per-file `sign_file`/`verify_file` on the Mach-O tool (TDD)

Spike-1: the app's `codesign --deep` does **not** sign Mach-Os under `Resources/`, and `--deep --strict` verify skips them too. The payload must sign + verify each file itself. Add the two IO callbacks.

**Files:**
- Modify: `orchestrator/lib/orchestrator/macho/tool.ex`, `orchestrator/lib/orchestrator/macho/otool.ex`
- Test: `orchestrator/test/orchestrator/payload_enchant_test.exs` (add a `@tag :macos` case)

**Interfaces — Produces:** `Macho.Tool.sign_file(path) :: :ok`, `Macho.Tool.verify_file(path) :: :ok | {:error, String.t()}`

- [ ] **Step 1: Add the `@tag :macos` failing test** (append inside `Orchestrator.Payload.EnchantTest`):

```elixir
  @tag :macos
  test "Otool.sign_file then verify_file round-trips on a freshly-edited dylib" do
    t = Path.join(System.tmp_dir!(), "sf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(t)
    on_exit(fn -> File.rm_rf!(t) end)
    src = Path.join(t, "x.c")
    dy = Path.join(t, "libx.dylib")
    File.write!(src, "int x(void){return 1;}\n")
    {_, 0} = System.cmd("clang", ["-dynamiclib", "-install_name", "@rpath/libx.dylib", src, "-o", dy])
    # install_name edit invalidates/relinker-signs; verify_file then sign_file must yield a strict-valid sig
    {_, 0} = System.cmd("install_name_tool", ["-id", "@rpath/libx.dylib", dy], stderr_to_stdout: true)
    assert :ok = Orchestrator.Macho.Otool.sign_file(dy)
    assert :ok = Orchestrator.Macho.Otool.verify_file(dy)
  end
```

- [ ] **Step 2: Run it on macOS, watch it fail**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/payload_enchant_test.exs --include macos'`
Expected: FAIL — `Orchestrator.Macho.Otool.sign_file/1` undefined.

- [ ] **Step 3: Add the callbacks to the behaviour** — append to `orchestrator/lib/orchestrator/macho/tool.ex` (before the final `end`):

```elixir
  @callback sign_file(Path.t()) :: :ok
  @callback verify_file(Path.t()) :: :ok | {:error, String.t()}
```

- [ ] **Step 4: Implement them in the adapter** — append to `orchestrator/lib/orchestrator/macho/otool.ex` (before the private helpers):

```elixir
  @impl true
  def sign_file(path) do
    {_, 0} = System.cmd("codesign", ["--force", "--sign", "-", path], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def verify_file(path) do
    case System.cmd("codesign", ["--verify", "--strict", path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end
```

- [ ] **Step 5: Run the macOS test to verify it passes**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/payload_enchant_test.exs --include macos'`
Expected: PASS.

- [ ] **Step 6: Format + suite + commit**
Run: `mise run fmt && mise exec -- sh -c 'cd orchestrator && mix test --include macos' && mise run lint`
```bash
git add orchestrator/lib/orchestrator/macho/tool.ex orchestrator/lib/orchestrator/macho/otool.ex orchestrator/test/orchestrator/payload_enchant_test.exs
git commit -m "feat(enchant): per-file sign_file/verify_file Macho.Tool callbacks (Resources/ not covered by --deep)"
```

---

## Task 3: `Payload.Enchant.stage/3` + `verify/2` + `relocate/2` runner + `mix payload.enchant` (TDD)

The IO runner. The `@tag :macos` test builds a **synthetic enchant sub-prefix** with clang (stub `libenchant` → stub `libglibstub` dep + a stub provider), stages it, relocates with bundle-root `enchant/lib`, per-file signs, verifies, then compiles a **jinx-stub module via the shim** and `dlopen`s it — codifying the facet-A spike. No published feedstock needed.

**Files:**
- Modify: `orchestrator/lib/orchestrator/payload/enchant.ex` (add the runner)
- Create: `orchestrator/lib/mix/tasks/payload.enchant.ex`
- Test: `orchestrator/test/orchestrator/payload_enchant_test.exs` (add the `@tag :macos` e2e)

**Interfaces — Produces:**
- `Payload.Enchant.stage(app :: Path.t(), conda_prefix :: Path.t(), tool :: module) :: :ok`
- `Payload.Enchant.relocate(app :: Path.t(), tool :: module) :: :ok` (called by `Relocate`, Task 4)
- `Payload.Enchant.verify(app :: Path.t(), conda_prefix :: Path.t(), tool :: module) :: :ok | {:error, term}`

- [ ] **Step 1: Write the failing e2e fixture test** (append inside `Orchestrator.Payload.EnchantTest`):

```elixir
  @tag :macos
  test "stage+relocate a synthetic enchant sub-prefix → self-contained; jinx-stub compiles & loads" do
    t = Path.join(System.tmp_dir!(), "ench-#{System.unique_integer([:positive])}")
    libdir = Path.join(t, "conda/lib")
    incdir = Path.join(t, "conda/include/enchant-2")
    File.mkdir_p!(Path.join(libdir, "enchant-2"))
    File.mkdir_p!(incdir)
    app = Path.join(t, "Emacs.app")
    File.mkdir_p!(Path.join([app, "Contents", "Resources", "site-lisp"]))
    on_exit(fn -> File.rm_rf!(t) end)
    cl = fn args -> {_, 0} = System.cmd("clang", args, stderr_to_stdout: true) end

    # synthetic conda enchant prefix: libglibstub (leaf), libenchant-2.2 (links glibstub),
    # unversioned symlink, a provider that links libenchant, a header, the .pc, the CLI.
    File.write!(Path.join(t, "g.c"), "int gstub(void){return 1;}\n")
    File.write!(Path.join(t, "e.c"), "int gstub(void); int enchant_v(void){return gstub()+1;}\n")
    File.write!(Path.join(t, "p.c"), "int enchant_v(void); int prov(void){return enchant_v();}\n")
    cl.(["-dynamiclib", "-install_name", "@rpath/libglibstub.dylib", "-Wl,-headerpad_max_install_names",
         Path.join(t, "g.c"), "-o", Path.join(libdir, "libglibstub.dylib")])
    cl.(["-dynamiclib", "-install_name", "@rpath/libenchant-2.2.dylib", "-Wl,-headerpad_max_install_names",
         "-L", libdir, "-lglibstub", "-Wl,-rpath," <> libdir,
         Path.join(t, "e.c"), "-o", Path.join(libdir, "libenchant-2.2.dylib")])
    File.ln_s!("libenchant-2.2.dylib", Path.join(libdir, "libenchant-2.dylib"))
    cl.(["-bundle", "-Wl,-headerpad_max_install_names", "-L", libdir, "-lenchant-2", "-Wl,-rpath," <> libdir,
         Path.join(t, "p.c"), "-o", Path.join([libdir, "enchant-2", "enchant_applespell.so"])])
    File.write!(Path.join(incdir, "enchant.h"), "int enchant_v(void);\n")
    File.write!(Path.join([t, "conda/lib/pkgconfig/enchant-2.pc"]) |> tap(&File.mkdir_p!(Path.dirname(&1))),
                "prefix=#{Path.join(t, "conda")}\nLibs: -L${prefix}/lib -lenchant-2\n")
    for b <- ["enchant-2", "enchant-lsmod-2"] do
      File.write!(Path.join(t, "#{b}.c"), "int enchant_v(void); int main(void){return enchant_v()-2;}\n")
      cl.(["-Wl,-headerpad_max_install_names", "-L", libdir, "-lenchant-2", "-Wl,-rpath," <> libdir,
           Path.join(t, "#{b}.c"), "-o", Path.join(Path.join(t, "conda/bin") |> tap(&File.mkdir_p!/1), b)])
    end

    conda = Path.join(t, "conda")
    assert :ok = Orchestrator.Payload.Enchant.stage(app, conda, Orchestrator.Macho.Otool)
    assert :ok = Orchestrator.Payload.Enchant.relocate(app, Orchestrator.Macho.Otool)
    assert :ok = Orchestrator.Payload.Enchant.verify(app, conda, Orchestrator.Macho.Otool)

    ench = Path.join(app, "Contents/Resources/enchant")
    assert File.exists?(Path.join(ench, "lib/libenchant-2.2.dylib"))
    assert File.exists?(Path.join(ench, "lib/libenchant-2.dylib"))           # unversioned symlink (spike-A)
    assert File.exists?(Path.join(ench, "lib/libglibstub.dylib"))            # closure pulled into enchant/lib
    assert File.exists?(Path.join(ench, "lib/enchant-2/enchant_applespell.so"))
    assert File.exists?(Path.join(ench, "share/enchant-2/enchant.ordering"))
    assert File.exists?(Path.join(app, "Contents/Resources/site-lisp/site-start.el"))

    # jinx-stub: jinx's real compile flags + the bundled shim → compile, link, dlopen.
    File.write!(Path.join(t, "jinx-mod.c"),
      "int enchant_v(void); int jinx_probe(void){return enchant_v()+40;}\n")
    pkgout =
      System.cmd(Path.join(ench, "bin/pkg-config"), ["--cflags", "--libs", "enchant-2"])
      |> elem(0) |> String.trim() |> String.split()
    cl.(["-I.", "-O2", "-Wall", "-Wextra", "-fPIC", "-shared",
         "-o", Path.join(t, "jinx-mod.so"), Path.join(t, "jinx-mod.c")] ++ pkgout)
    File.write!(Path.join(t, "host.c"),
      ~S|#include <dlfcn.h>
#include <stdio.h>
int main(int c,char**v){void*h=dlopen(v[1],RTLD_NOW);if(!h){printf("FAIL %s\n",dlerror());return 1;}
int(*f)(void)=(int(*)(void))dlsym(h,"jinx_probe");return f()==42?0:3;}|)
    cl.(["-o", Path.join(t, "host"), Path.join(t, "host.c")])
    assert {_, 0} = System.cmd(Path.join(t, "host"), [Path.join(t, "jinx-mod.so")], stderr_to_stdout: true)
  end
```

- [ ] **Step 2: Run it, watch it fail**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/payload_enchant_test.exs --include macos'`
Expected: FAIL — `Payload.Enchant.stage/3` undefined.

- [ ] **Step 3: Add the runner** to `orchestrator/lib/orchestrator/payload/enchant.ex` (replace the `__macho__/0` stub with these). The closure walk and rpath logic reuse `Orchestrator.Macho` exactly as `Relocate` does, but with bundle-root `enchant/lib`:

```elixir
  @spec ench_dir(Path.t()) :: Path.t()
  defp ench_dir(app), do: Path.join(Path.expand(app), @enchant_rel)

  @doc "Copy enchant + its closure out of `conda_prefix` into the app sub-prefix (no relocation yet)."
  @spec stage(Path.t(), Path.t(), module) :: :ok
  def stage(app, conda_prefix, tool \\ Orchestrator.Macho.Otool) do
    ench = ench_dir(app)
    lib = Path.join(ench, "lib")
    File.mkdir_p!(Path.join(lib, "enchant-2"))
    File.mkdir_p!(Path.join(ench, "include/enchant-2"))
    File.mkdir_p!(Path.join(ench, "lib/pkgconfig"))
    File.mkdir_p!(Path.join(ench, "share/enchant-2"))
    File.mkdir_p!(Path.join(ench, "bin"))
    src = fn rel -> Path.join(conda_prefix, rel) end

    # 1. libenchant + the providers are the relocation ROOTS; copy them in...
    cp!(src.("lib/libenchant-2.2.dylib"), Path.join(lib, "libenchant-2.2.dylib"))
    File.ln_s!("libenchant-2.2.dylib", Path.join(lib, "libenchant-2.dylib"))     # spike-A: -lenchant-2 target
    for so <- Path.wildcard(Path.join(src.("lib/enchant-2"), "enchant_*.so")),
        do: cp!(so, Path.join([lib, "enchant-2", Path.basename(so)]))

    # 2. ...then BFS their foreign closure into enchant/lib (Macho primitives, bundle-root = lib).
    roots = [Path.join(lib, "libenchant-2.2.dylib") | Path.wildcard(Path.join(lib, "enchant-2/*.so"))]
    copy_closure(roots, lib, Path.join(conda_prefix, "lib"), tool)

    # 3. SDK + CLIs + generated files.
    for h <- Path.wildcard(Path.join(src.("include/enchant-2"), "*.h")),
        do: cp!(h, Path.join([ench, "include/enchant-2", Path.basename(h)]))
    for b <- ["enchant-2", "enchant-lsmod-2"], File.exists?(src.("bin/#{b}")),
        do: cp!(src.("bin/#{b}"), Path.join([ench, "bin", b]))
    File.write!(Path.join(ench, "lib/pkgconfig/enchant-2.pc"), pc_contents())
    write_exec!(Path.join(ench, "bin/pkg-config"), pkgconfig_shim())
    File.write!(Path.join(ench, "share/enchant-2/enchant.ordering"), ordering_contents())
    File.write!(Path.join(app, "Contents/Resources/site-lisp/site-start.el"), site_start_el())
    :ok
  end

  @doc "Normalize ids/deps/rpaths within the staged sub-prefix to @rpath/@loader_path, then per-file sign."
  @spec relocate(Path.t(), module) :: :ok
  def relocate(app, tool \\ Orchestrator.Macho.Otool) do
    ench = ench_dir(app)
    lib = Path.join(ench, "lib")

    for m <- machos(ench, tool) do
      tool.set_id(m, "@rpath/" <> Path.basename(m))

      for dep <- tool.deps(m), Macho.classify(dep) == :foreign do
        base = Path.basename(dep)
        if File.exists?(Path.join(lib, base)), do: tool.change(m, dep, "@rpath/" <> base)
      end

      tool.add_rpath(m, "@loader_path/" <> Macho.relpath(lib, Path.dirname(m)))
      for rp <- tool.rpaths(m), Macho.classify(rp) == :foreign, do: tool.delete_rpath(m, rp)
      tool.sign_file(m)
    end

    :ok
  end

  @doc "Gate: otool self-containment over enchant/** + per-file codesign verify + build-prefix leak check."
  @spec verify(Path.t(), Path.t(), module) :: :ok | {:error, term}
  def verify(app, conda_prefix, tool \\ Orchestrator.Macho.Otool) do
    ench = ench_dir(app)
    lib = Path.join(ench, "lib")
    basenames = lib |> File.ls!() |> MapSet.new()
    machos = for m <- machos(ench, tool), do: %{path: m, deps: tool.deps(m), rpaths: tool.rpaths(m)}

    with [] <- Macho.gate_violations(machos, basenames),
         :ok <- verify_sigs(machos, tool),
         :ok <- leak_check(ench, conda_prefix) do
      IO.puts("enchant_gate: PASS (#{ench} self-contained)")
      :ok
    else
      {:error, _} = e -> e
      violations -> {:error, violations}
    end
  end

  # --- helpers (mirror Orchestrator.Relocate's closure walk, bundle-root = enchant/lib) ---
  defp machos(ench, tool) do
    Path.join(ench, "**") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.filter(&tool.macho?/1)
  end

  defp copy_closure(roots, lib, conda_lib, tool) do
    queue = Enum.flat_map(roots, fn f -> Macho.bundleable(tool.deps(f)) end)
    do_copy(queue, MapSet.new(), lib, conda_lib, tool)
  end

  defp do_copy([], _seen, _lib, _src, _tool), do: :ok

  defp do_copy([dep | rest], seen, lib, src, tool) do
    base = Path.basename(dep)

    if MapSet.member?(seen, base) do
      do_copy(rest, seen, lib, src, tool)
    else
      from = resolve(dep, src)
      dest = Path.join(lib, base)
      new = if from && File.exists?(from) and not File.exists?(dest) do
              cp!(from, dest); Macho.bundleable(tool.deps(dest))
            else
              []
            end
      do_copy(rest ++ new, MapSet.put(seen, base), lib, src, tool)
    end
  end

  defp resolve("@rpath/" <> base, src), do: Path.join(src, base)
  defp resolve("/" <> _ = abs, _src), do: abs
  defp resolve(_, _), do: nil

  defp verify_sigs(machos, tool) do
    Enum.reduce_while(machos, :ok, fn %{path: p}, _ ->
      case tool.verify_file(p) do
        :ok -> {:cont, :ok}
        {:error, m} -> {:halt, {:error, {:unsigned, p, m}}}
      end
    end)
  end

  defp leak_check(ench, conda_prefix) do
    hits =
      Path.wildcard(Path.join(ench, "**"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn f -> File.read!(f) |> :binary.match(conda_prefix) != :nomatch end)

    if hits == [], do: :ok, else: {:error, {:build_prefix_leak, hits}}
  end

  defp cp!(from, to), do: (File.cp!(from, to); File.chmod!(to, 0o644))
  defp write_exec!(path, body), do: (File.write!(path, body); File.chmod!(path, 0o755))
```

> Implementer notes: keep `mix format` clean (the `(a; b)` one-liners above must be expanded to multi-line `do…end` blocks). `leak_check/2` reads each staged file — fine for the small enchant subtree. The `set_id` on a non-dylib (the CLIs are executables, no id) is a no-op-or-error tolerated like `Relocate`; if `install_name_tool -id` errors on an executable, guard with `if tool.id(m)`.

- [ ] **Step 4: Write the Mix task** — `orchestrator/lib/mix/tasks/payload.enchant.ex`:

```elixir
defmodule Mix.Tasks.Payload.Enchant do
  @shortdoc "Stage + relocate + verify the bundled enchant payload into an Emacs.app"
  @moduledoc "Usage: `mix payload.enchant <Emacs.app path> <conda_prefix>` (conda_prefix = `$CONDA_PREFIX`)."
  use Mix.Task
  alias Orchestrator.Payload.Enchant

  @impl true
  def run([app, conda_prefix]) do
    :ok = Enchant.stage(app, conda_prefix)
    :ok = Enchant.relocate(app)

    case Enchant.verify(app, conda_prefix) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("enchant payload gate failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix payload.enchant <Emacs.app path> <conda_prefix>")
end
```

- [ ] **Step 5: Run the e2e test to verify it passes**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/payload_enchant_test.exs --include macos'`
Expected: PASS — synthetic enchant staged, self-contained, gate green, and the jinx-stub compiled via the shim + `dlopen`ed (host exits 0 ⇒ `jinx_probe()==42`).

> **Validation point:** if the closure walk leaves a foreign dep (gate fails), inspect with `otool -L` on the staged dylib and confirm `conda/lib` is the single libdir — fix `resolve/2`, don't weaken the gate. If `leak_check` trips on the `.pc`, confirm `pc_contents/0` has no absolute path (it must be `${pcfiledir}`-relative).

- [ ] **Step 6: Format + suite + commit**
Run: `mise run fmt && mise exec -- sh -c 'cd orchestrator && mix test --include macos' && mise run lint`
```bash
git add orchestrator/lib/orchestrator/payload/enchant.ex orchestrator/lib/mix/tasks/payload.enchant.ex orchestrator/test/orchestrator/payload_enchant_test.exs
git commit -m "feat(enchant): stage/relocate/verify runner + mix payload.enchant (synthetic-fixture e2e: jinx compiles & loads)"
```

---

## Task 4: wire the payload into `Orchestrator.Relocate` (TDD)

One bounded change: exclude the enchant subtree from the Frameworks walk, relocate the payload before the single deep sign, and run both gates.

**Files:**
- Modify: `orchestrator/lib/orchestrator/relocate.ex`
- Test: `orchestrator/test/orchestrator/relocate_test.exs`

- [ ] **Step 1: Add a failing exclusion test** (append inside `Orchestrator.RelocateTest`, reuse its `setup`):

```elixir
  @tag :macos
  test "a Mach-O under Contents/Resources/enchant is excluded from the Frameworks closure", %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    ench = Path.join(app, "Contents/Resources/enchant/lib")
    File.mkdir_p!(ench)
    File.write!(Path.join(t, "main.c"), "int main(void){return 0;}\n")
    File.write!(Path.join(t, "e.c"), "int e(void){return 1;}\n")
    clang!(["-Wl,-headerpad_max_install_names", Path.join(t, "main.c"), "-o",
            Path.join(app, "Contents/MacOS/App")])
    clang!(["-dynamiclib", "-install_name", "@rpath/libench.dylib", Path.join(t, "e.c"),
            "-o", Path.join(ench, "libench.dylib")])

    assert Orchestrator.Relocate.run(app, lib) == :ok
    # the enchant dylib must NOT have been copied into Frameworks by the Emacs relocator
    refute File.exists?(Path.join([app, "Contents", "Frameworks", "libench.dylib"]))
  end
```

- [ ] **Step 2: Run it, watch it fail** (the current `machos/2` globs everything, so `libench.dylib` would be processed — but since nothing references it, the assertion may already pass; the real risk is the *closure pulling enchant deps into Frameworks*. Make the test meaningful by also asserting the payload subtree is untouched):
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/relocate_test.exs --include macos'`
Expected: confirm current behavior, then make the exclusion explicit in code.

- [ ] **Step 3: Exclude the enchant subtree in `machos/2`** — modify `orchestrator/lib/orchestrator/relocate.ex`:

```elixir
  defp machos(app, tool) do
    enchant = Path.join([app, Orchestrator.Payload.Enchant.enchant_rel()]) <> "/"

    Path.join(app, "**")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, enchant))
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&tool.macho?/1)
  end
```

- [ ] **Step 4: Relocate the payload before signing, gate both** — modify `Relocate.run/3` so that, after the Frameworks closure is built and rewritten but **before** `tool.sign_bundle(app)`, the payload is relocated; and after the bundle verify, the payload gate runs too. Replace the body of `run/3`:

```elixir
  def run(app, build_libdir, tool \\ Orchestrator.Macho.Otool) do
    app = Path.expand(app)
    fw = Path.join([app, "Contents", "Frameworks"])
    File.mkdir_p!(fw)

    copy_closure(machos(app, tool), fw, build_libdir, tool)
    Enum.each(machos(app, tool), &rewrite(&1, fw, tool))

    # enchant payload (if staged): relocate its subtree BEFORE the single deep sign so the deep
    # sign covers it too — but its Mach-Os are ALSO per-file signed by the payload (spike-1:
    # --deep skips Resources/). No-op when the payload was not staged.
    if File.dir?(Path.join([app, Orchestrator.Payload.Enchant.enchant_rel()])) do
      Orchestrator.Payload.Enchant.relocate(app, tool)
    end

    tool.sign_bundle(app)

    case tool.verify_bundle(app) do
      :ok ->
        IO.puts("sign_gate: PASS (#{app} signature valid)")
        gate(app, fw, tool)

      {:error, reason} ->
        IO.puts("sign_gate: FAIL — #{reason}")
        {:error, {:signature_invalid, reason}}
    end
  end
```

> Note: the payload's **own** gate (`Payload.Enchant.verify/3`, with the leak check) is invoked by `mix payload.enchant` in the build pipeline (Task 6), which runs *after* `mix relocate`. `Relocate` only needs to (a) not flatten the subtree and (b) include it in the deep sign. Keeping the payload-gate in its own task keeps `Relocate`'s signature unchanged for the existing callers.

- [ ] **Step 5: Run the relocate suite to verify pass**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/relocate_test.exs --include macos'`
Expected: PASS — existing relocation test still green; enchant dylib not in Frameworks.

- [ ] **Step 6: Format + suite + commit**
Run: `mise run fmt && mise exec -- sh -c 'cd orchestrator && mix test --include macos' && mise run lint`
```bash
git add orchestrator/lib/orchestrator/relocate.ex orchestrator/test/orchestrator/relocate_test.exs
git commit -m "feat(enchant): exclude Resources/enchant from Frameworks walk; relocate payload before deep sign"
```

---

## Task 5: PATH exposure — `enchant-2` + `enchant-lsmod-2` on the mise PATH (TDD)

**Files:**
- Modify: `orchestrator/lib/orchestrator/naming.ex`, `aqua/registry.yaml`, `orchestrator/test/orchestrator/registry_contract_test.exs`

- [ ] **Step 1: Extend the `bundle_binaries/0` test** — open `orchestrator/test/orchestrator/naming_test.exs` (or `registry_contract_test.exs`) and assert the two new entries are present. Add to the relevant test:

```elixir
  test "bundle_binaries includes the enchant CLIs under Resources/enchant/bin" do
    bins = Orchestrator.Naming.bundle_binaries()
    assert "Emacs.app/Contents/Resources/enchant/bin/enchant-2" in bins
    assert "Emacs.app/Contents/Resources/enchant/bin/enchant-lsmod-2" in bins
  end
```

- [ ] **Step 2: Run it, watch it fail**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/naming_test.exs'`
Expected: FAIL — entries not present.

- [ ] **Step 3: Add them to `bundle_binaries/0`** — `orchestrator/lib/orchestrator/naming.ex`:

```elixir
  def bundle_binaries do
    [
      "Emacs.app/Contents/MacOS/Emacs",
      "Emacs.app/Contents/MacOS/bin/emacsclient",
      "Emacs.app/Contents/MacOS/bin/etags",
      "Emacs.app/Contents/MacOS/bin/ebrowse",
      "Emacs.app/Contents/Resources/enchant/bin/enchant-2",
      "Emacs.app/Contents/Resources/enchant/bin/enchant-lsmod-2"
    ]
  end
```

- [ ] **Step 4: Add the `files:` entries to `aqua/registry.yaml`** — under **each** package's `overrides[0].files`, append:

```yaml
          - name: enchant-2
            src: "{{.AssetWithoutExt}}/Emacs.app/Contents/Resources/enchant/bin/enchant-2"
          - name: enchant-lsmod-2
            src: "{{.AssetWithoutExt}}/Emacs.app/Contents/Resources/enchant/bin/enchant-lsmod-2"
```

- [ ] **Step 5: Update `registry_contract_test.exs`** so the contract test (which binds `bundle_binaries/0` ↔ the registry `files:` `src` set) still passes with the two new entries. Read the test; if it asserts an exact set/count, add the two `enchant-…` src paths to the expected set.

- [ ] **Step 6: Run the contract suite to verify it passes**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/registry_contract_test.exs test/orchestrator/naming_test.exs'`
Expected: PASS — registry `files:` and `bundle_binaries/0` agree.

- [ ] **Step 7: Format + suite + commit**
Run: `mise run fmt && mise run test && mise run lint`
```bash
git add orchestrator/lib/orchestrator/naming.ex aqua/registry.yaml orchestrator/test/orchestrator/registry_contract_test.exs orchestrator/test/orchestrator/naming_test.exs
git commit -m "feat(enchant): expose enchant-2 + enchant-lsmod-2 on PATH (Naming + aqua registry + contract test)"
```

---

## Task 6: **[PHASE-0-GATED]** pixi dep, build wiring, and cleanroom e2e

**DO NOT START until Phase 0 (feedstock published to a channel) is done** — Step 1 cannot resolve otherwise. Everything here needs the *real* feedstock enchant (providers + applespell + the `dladdr` patch); the synthetic fixtures of Tasks 1–5 cannot cover it.

**Files:**
- Modify: `versions/master/pixi.toml`, `versions/emacs-31/pixi.toml`, both `pixi.lock`
- Create: `pipeline/stage-enchant`
- Modify: `mise.toml`

- [ ] **Step 1: Add the dependency + channel, then re-lock** — in **both** `versions/<v>/pixi.toml`, add the feedstock channel and the dep:

```toml
[workspace]
channels = ["conda-forge", "<feedstock-channel>"]   # e.g. "https://prefix.dev/djgoku"

[dependencies]
enchant = "2.8.2"
```

Run: `mise exec -- pixi install --manifest-path versions/master/pixi.toml` (then emacs-31).
Expected: resolves; `pixi.lock` gains an `enchant 2.8.2` entry **with a `sha256`**. Confirm: `grep -A2 'name: enchant' versions/master/pixi.lock` shows the pinned hash. (Reproducibility gate — see Codex AREA 4.)

- [ ] **Step 2: Create `pipeline/stage-enchant`** (mirrors `pipeline/relocate`):

```bash
#!/usr/bin/env bash
# pipeline/stage-enchant <version> — stage + relocate + verify the bundled enchant payload into
# build/<version>/Emacs.app (Elixir: mix payload.enchant). Runs AFTER `mise run build` and
# `mise run relocate`. conda_prefix = dirname of the build's conda-prefix-lib.txt content.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-master}"
APP="$HERE/build/$VERSION/Emacs.app"
LIB="$HERE/build/$VERSION/conda-prefix-lib.txt"
[ -d "$APP" ] || { echo "FATAL: $APP missing — run 'mise run build && mise run relocate $VERSION' first"; exit 1; }
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
CONDA_PREFIX_DIR="$(dirname "$(cat "$LIB")")"   # .../envs/default/lib -> .../envs/default
cd "$HERE/orchestrator"
mise exec -- mix payload.enchant "../build/$VERSION/Emacs.app" "$CONDA_PREFIX_DIR"
```

> Ordering note: stage-enchant must run **after** `mise run relocate` so the payload's per-file signatures are not clobbered, and so the relocator's deep sign already ran over the rest. (`Relocate` already deep-signs; the payload self-signs its own files. Run order in the pipeline: build → relocate → stage-enchant → package.) If a later deep re-sign is ever added, ensure it does not strip the payload's per-file sigs (spike-1: `--deep` does not touch `Resources/`, so it won't).

- [ ] **Step 3: Add the mise task + extend cleanroom** — in `mise.toml`, add:

```toml
[tasks.stage-enchant]
description = "Stage + relocate + verify the bundled enchant payload (after build+relocate); args: [version]"
run = "bash pipeline/stage-enchant"
```

and extend `[tasks.cleanroom]` (after the existing `--batch` gate, with the pixi env still moved aside) with the enchant proofs:

```sh
ENCH="$APP/Contents/Resources/enchant"
echo ">> [3] enchant resolves providers from the bundle alone (no pixi env present)"
"$ENCH/bin/enchant-lsmod-2"                      # lists applespell (+ hunspell) from the bundle
echo ">> [4] build-prefix leak check"
if strings "$ENCH/lib/"*.dylib "$ENCH/lib/enchant-2/"*.so "$ENCH/lib/pkgconfig/enchant-2.pc" \
   | grep -qE '/(envs|\.pixi)/'; then echo "FATAL: build-prefix leak in enchant payload"; exit 1; fi
echo ">> [5] jinx end-to-end (needs Xcode CLT in the VM)"
"$APP/Contents/MacOS/Emacs" -Q --batch \
  --eval "(progn (setq package-user-dir (make-temp-file \"elpa\" t))
                 (require 'package) (add-to-list 'package-archives '(\"gnu\" . \"https://elpa.gnu.org/packages/\")) (add-to-list 'package-archives '(\"nongnu\" . \"https://elpa.nongnu.org/nongnu/\"))
                 (package-initialize) (package-refresh-contents) (package-install 'jinx)
                 (load (expand-file-name \"Contents/Resources/site-lisp/site-start.el\" \"$APP\"))
                 (require 'jinx) (with-temp-buffer (jinx-mode 1) (insert \"helllo\") (jinx--load-module) (message \"jinx ok\")))"
echo ">> [6] symlinked-launch (O9): dladdr path semantics under a symlink"
LN="$(mktemp -d)/Emacs.app"; ln -s "$APP" "$LN"
"$LN/Contents/Resources/enchant/bin/enchant-lsmod-2" >/dev/null && echo "   symlinked launch OK"
```

- [ ] **Step 4: Run the full local build + payload + cleanroom**
Run: `mise run build && mise run stage-enchant && mise run relocate && mise run cleanroom` (per R7: copy the payload **before** `relocate`, which then relocates + per-file-signs it, deep-signs/seals the whole app, and runs both gates).
Expected: `enchant-lsmod-2` lists **applespell** (+ hunspell); no leak; jinx compiles its module via the bundled shim and `jinx ok` prints; symlinked launch OK.

> **Validation points (real artifact):** confirm applespell appears in `enchant-lsmod-2` (resolves **O6**; hunspell is bring-your-own per spec §13 — no dict bundled). Confirm the jinx module compiled with no system pkg-config present (the shim worked). Confirm O9 (symlinked launch) — if `dladdr` returns the symlink-resolved path and providers still load, record it; if not, the payload must resolve the real path before launch.

- [ ] **Step 5: Commit**
```bash
git add versions/master/pixi.toml versions/master/pixi.lock versions/emacs-31/pixi.toml versions/emacs-31/pixi.lock pipeline/stage-enchant mise.toml
git commit -m "feat(enchant): pixi dep (pinned) + pipeline/stage-enchant + cleanroom enchant/jinx/leak/symlink e2e"
```

---

## Task 7: resolve O1/O2/O5, record findings, reconcile the spec

**Files:**
- Modify: `docs/superpowers/validation-log.md`, `docs/superpowers/specs/2026-06-25-bundled-enchant-payload-design.md`

- [ ] **Step 1: Confirm O1 (site-lisp path) from the real build** — after Task 6's build, verify the app's auto-loaded site-lisp dir:
Run: `ls build/master/Emacs.app/Contents/Resources/site-lisp/ && build/master/Emacs.app/Contents/MacOS/Emacs --batch --eval '(princ site-run-file)' && build/master/Emacs.app/Contents/MacOS/Emacs --batch --eval '(princ (mapconcat #\identity (seq-filter (lambda (d) (string-match-p "site-lisp" d)) load-path) "\n"))'`
Expected: `site-start` is the `site-run-file` and the app's `Contents/Resources/site-lisp` is on `load-path`. If the path differs, update `stage/3` (Task 3) to write `site-start.el` to the confirmed location and re-run.

- [ ] **Step 2: Record decisions for O2 + O5** in the validation log:
  - **O2 — pkg-config shim chosen** (not bundling real `pkgconf`): the shim is minimal, fully controls flags incl. `-Wl,-rpath`, refuses non-`enchant-2` queries, and is `exec-path`-scoped to jinx's compile — no global `pkg-config` shadowing.
  - **O5 — `site-start.el` keeps auto-load** but is discovery-only (no `DYLD_*`, no policy); opt out via `misemacs-enchant-disable` or `-Q`/`--no-site-file`.

- [ ] **Step 3: Append the enchant section to `docs/superpowers/validation-log.md`** — record: stock conda-forge enchant ships no providers (Phase-0 dependency justification); the spike-validated mechanics (codesign-skips-Resources, DYLD-dead/rpath-patch, ordering at `share/enchant-2/`, `dladdr` WILL-WORK, jinx compile/link/load, unversioned-symlink requirement); the real-artifact results from Task 6 (applespell present, O6/O9 outcomes).

- [ ] **Step 4: Flip resolved items in the spec** — in `docs/superpowers/specs/2026-06-25-bundled-enchant-payload-design.md` §15, mark O1/O2/O5 resolved with their outcomes; if O6/O9 were settled in Task 6, mark those too.

- [ ] **Step 5: Commit**
```bash
git add docs/superpowers/validation-log.md docs/superpowers/specs/2026-06-25-bundled-enchant-payload-design.md
git commit -m "docs(enchant): resolve O1/O2/O5, record spike + real-artifact findings, reconcile spec §15"
```

---

## Definition of Done

- [ ] `mise run test` green incl. the pure `Payload.Enchant` tests; on macOS the `@tag :macos` e2e (synthetic enchant → stage → relocate → per-file sign → verify → jinx-stub compiles & `dlopen`s) and the relocate exclusion test pass; ubuntu CI stays green (`:macos` excluded).
- [ ] `mix payload.enchant` stages a self-contained `Contents/Resources/enchant/` sub-prefix: closure in `enchant/lib`, providers in `enchant/lib/enchant-2`, the unversioned `libenchant-2.dylib` symlink, `${pcfiledir}` `.pc`, the `pkg-config` shim, `site-start.el`, and `share/enchant-2/enchant.ordering` (`*:applespell,hunspell`).
- [ ] The enchant gate passes: otool self-containment over `enchant/**`, per-file `codesign --verify --strict`, no build-prefix leak.
- [ ] `Orchestrator.Relocate` excludes `Resources/enchant/**` from the Frameworks walk and relocates the payload before the deep sign; existing relocation tests stay green.
- [ ] `enchant-2` + `enchant-lsmod-2` on the mise PATH (Naming + registry + contract test agree).
- [ ] **(Phase 0 done)** pixi pins `enchant 2.8.2` by `sha256`; `mise run cleanroom` shows `enchant-lsmod-2` listing applespell from the bundle, jinx compiling its module via the shim with no system pkg-config, no leak, and a symlinked launch resolving providers (O9).
- [ ] O1/O2/O5 resolved; O6/O9 recorded; validation log + spec §15 updated.

## Self-Review (author)

**Spec coverage:** §6 provenance → Task 6 (pixi dep + lock). §7 layout → `stage/3` (Task 3) + the e2e assertions. §8 seam + exclusion + per-file sign → Tasks 2–4. §9 `.pc` rewrite → `pc_contents/0` (Task 1) + e2e. §10 shim → `pkgconfig_shim/0` (Task 1, O2-hardened) + e2e + cleanroom. §11 site-start + self-heal → `site_start_el/0` (Task 1, spike-3 rpath-patch, O5 opt-out). §12 PATH → Task 5. §13 backend/ordering → `ordering_contents/0` + `share/enchant-2/` placement (spike-C). §14 gates → `verify/2` (otool + per-file sign + leak) Task 3, cleanroom Task 6. §15 O1/O2/O5/O6/O9 → Task 7 (+ Task 6 for the artifact-gated ones). S1/O3/O8/D spike findings are baked into Tasks 2/3/1/3 respectively.

**Placeholder scan:** the generated-file bytes, the runner, the Mix task, the e2e test, and the relocator edits are complete. The one external unknown — the **feedstock channel URL** — is `<feedstock-channel>` in Task 6 Step 1 (Phase-0 output, filled when the channel exists); flagged, not a code gap. The `mix format` one-liner expansions in Task 3 Step 3 are called out explicitly.

**Type/name consistency:** `Payload.Enchant` exposes `enchant_rel/0` (used by `Relocate.machos/2` and `run/3`), `pc_contents/0`, `pkgconfig_shim/0`, `site_start_el/0`, `ordering_contents/0`, `stage/3`, `relocate/2`, `verify/3`. The new `Macho.Tool` callbacks `sign_file/1` + `verify_file/1` match the `Otool` `@impl` and the `Payload.Enchant.relocate/2` + `verify_sigs/2` call sites. `Naming.bundle_binaries/0` paths match the registry `files:` `src` and the `stage/3` write locations (`Contents/Resources/enchant/bin/{enchant-2,enchant-lsmod-2}`).

**Scope:** single subsystem (the enchant payload). pinentry, native-comp, Developer-ID, and additional arches stay out (spec §2). Phase 0 (publishing the feedstock) is an external precondition, not a task here.
```
