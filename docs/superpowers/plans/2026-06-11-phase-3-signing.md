# Phase 3 — Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "the shipped bundle has a valid ad-hoc signature" a permanent pipeline invariant (`verify_bundle`), close the §12 second-Mac risk with a pristine-VM transport proof, and record Decision F (ad-hoc sufficient; Developer ID deferred) across the docs.

**Architecture:** Phase 3 is a light validate-and-document phase (spec: `docs/superpowers/specs/2026-06-11-phase-3-signing-design.md`). The only code change is one new `Macho.Tool` callback (`verify_bundle/1` → `codesign --verify --deep --strict`) wired into `Orchestrator.Relocate.run/3` right after `sign_bundle`, following the existing pure-core + IO-adapter pattern. The transport proof reuses pregate's `--cmd` mode (no new VM machinery). The quarantine/Gatekeeper evidence (E1–E6) is already validated and recorded in `~/.claude/knowledge-base/macos-gatekeeper.md`; this plan copies it into the repo's validation log and reconciles the umbrella spec.

**Tech Stack:** Elixir 1.20 / ExUnit (`@tag :macos` integration tests); `codesign` via `System.cmd`; pregate + tart (`ghcr.io/cirruslabs/macos-tahoe-base:latest`) for the transport proof; mise tasks (`mise run test|lint|fmt`).

---

## Pre-validated facts this plan relies on (do not re-derive)

- Tampering a sealed Frameworks dylib after a deep ad-hoc sign makes
  `codesign --verify --deep --strict <App.app>` exit 1 with
  `main executable failed strict validation` + `In subcomponent: …/<lib>.dylib`
  (validated 2026-06-11 on a clang fixture bundle).
- `codesign -dv <app>` prints `Signature=adhoc` for ad-hoc bundles.
- Quarantine/Gatekeeper evidence E1–E6: see the spec §2 and
  `~/.claude/knowledge-base/macos-gatekeeper.md`. Ad-hoc is sufficient for the
  aqua/mise path; Gatekeeper blocks only quarantined code; approval caches by cdhash.
- pregate pipes the working tree into a fresh macOS VM with
  `tar --no-xattrs` + `COPYFILE_DISABLE=1` and its default excludes are
  `.git node_modules target _build deps dist` — so `build/` (the relocated app,
  ~150 MB) IS included; `pregate --macos --cmd '<cmd>'` runs `<cmd>` via `sh -c`
  with cwd = the tree root in the guest, and reports PASS/FAIL + log.
- `mise run test` = `cd orchestrator && mix deps.get && mix test --warnings-as-errors`;
  on this macOS host the `:macos`-tagged tests run (excluded only off Darwin).

## File Structure

| Path | Change | Responsibility |
|---|---|---|
| `orchestrator/lib/orchestrator/macho/tool.ex` | modify | add `verify_bundle/1` callback |
| `orchestrator/lib/orchestrator/macho/otool.ex` | modify | implement it via `codesign --verify --deep --strict` |
| `orchestrator/lib/orchestrator/relocate.ex` | modify | call it after `sign_bundle`; new error shape `{:signature_invalid, reason}` |
| `orchestrator/lib/mix/tasks/relocate.ex` | modify | distinct error message for signature failure |
| `orchestrator/test/orchestrator/relocate_test.exs` | modify | `Signature=adhoc` + `--strict` asserts; post-sign-tamper failure test |
| `docs/superpowers/validation-log.md` | modify | "2026-06-11 — Phase 3" section (E1–E6, transport proof, Decision F) |
| `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` | modify | reconcile D5, §9.3, §12, §13, §14, §15 |

No new files; no CI changes; pregate scripts unchanged (the transport proof is a
one-off `--cmd` invocation, not a recipe edit).

---

## Task 1: `verify_bundle/1` — signature verification as a relocation invariant (TDD)

**Files:**
- Modify: `orchestrator/lib/orchestrator/macho/tool.ex`
- Modify: `orchestrator/lib/orchestrator/macho/otool.ex`
- Modify: `orchestrator/lib/orchestrator/relocate.ex`
- Modify: `orchestrator/lib/mix/tasks/relocate.ex`
- Test: `orchestrator/test/orchestrator/relocate_test.exs`

- [ ] **Step 1: Write the failing tests**

In `orchestrator/test/orchestrator/relocate_test.exs`:

(a) At the top of the file, after `@moduletag :macos`, add a tool stub that
delegates everything to the real adapter but mutates the bundle *after* signing
(simulating any future post-sign bundle edit). No `@impl` annotations — the
callback doesn't exist yet and `--warnings-as-errors` would trip on
"no such callback":

```elixir
  # Simulates a post-sign bundle mutation: signs for real, then tampers a sealed
  # dylib — verify_bundle must catch this (spec 2026-06-11 §3.1).
  defmodule TamperAfterSignTool do
    @behaviour Orchestrator.Macho.Tool
    alias Orchestrator.Macho.Otool
    defdelegate macho?(p), to: Otool
    defdelegate id(p), to: Otool
    defdelegate deps(p), to: Otool
    defdelegate rpaths(p), to: Otool
    defdelegate set_id(p, new), to: Otool
    defdelegate change(p, old, new), to: Otool
    defdelegate add_rpath(p, rp), to: Otool
    defdelegate delete_rpath(p, rp), to: Otool
    defdelegate verify_bundle(p), to: Otool

    def sign_bundle(app) do
      :ok = Otool.sign_bundle(app)
      tampered = Path.join([app, "Contents", "Frameworks", "libfoo.dylib"])
      File.write!(tampered, <<0>>, [:append])
      :ok
    end
  end
```

(b) In the first test (`"relocate makes a fixture bundle self-contained…"`),
strengthen the existing codesign assert (line 85) and add the adhoc check —
replace:

```elixir
    assert {_, 0} = System.cmd("codesign", ["--verify", "--deep", app], stderr_to_stdout: true)
```

with:

```elixir
    assert {_, 0} =
             System.cmd("codesign", ["--verify", "--deep", "--strict", app],
               stderr_to_stdout: true
             )

    {dv, 0} = System.cmd("codesign", ["-dv", app], stderr_to_stdout: true)
    assert dv =~ "Signature=adhoc"
```

(c) Add a new test at the end of the module (reuses the setup fixture):

```elixir
  test "relocate fails with {:signature_invalid, _} when the bundle is mutated after signing",
       %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "main.c"), "int bar(void); int main(void){return bar()-5;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libfoo.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libfoo.dylib")
    ])

    clang!([
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lfoo",
      "-Wl,-rpath," <> lib,
      Path.join(t, "main.c"),
      "-o",
      Path.join(app, "Contents/MacOS/App")
    ])

    assert {:error, {:signature_invalid, reason}} =
             Orchestrator.Relocate.run(app, lib, TamperAfterSignTool)

    assert reason =~ "failed strict validation"
  end
```

(The dylib is named `libfoo.dylib` so the stub's hardcoded tamper path matches
what relocation copies into `Contents/Frameworks/`.)

- [ ] **Step 2: Run the tests and watch the new one fail**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/relocate_test.exs --include macos'`
Expected: the new test FAILS — `Orchestrator.Macho.Otool.verify_bundle/1 is undefined`
(the stub's `defdelegate verify_bundle` compiles but the delegated function doesn't
exist; if compilation fails on that delegate instead, that is the same red state).
The strengthened asserts in (b) should pass (Phase 2 already signs validly).

- [ ] **Step 3: Implement — callback, adapter, runner wiring, mix-task message**

`orchestrator/lib/orchestrator/macho/tool.ex` — add after the `sign_bundle` callback:

```elixir
  @callback verify_bundle(Path.t()) :: :ok | {:error, String.t()}
```

`orchestrator/lib/orchestrator/macho/otool.ex` — add after `sign_bundle/1`:

```elixir
  @impl true
  def verify_bundle(app) do
    case System.cmd("codesign", ["--verify", "--deep", "--strict", app],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end
```

`orchestrator/lib/orchestrator/relocate.ex`:

1. Update the `@spec` and the body of `run/3`:

```elixir
  @spec run(Path.t(), Path.t(), module) ::
          :ok | {:error, [Macho.violation()] | {:signature_invalid, String.t()}}
  def run(app, build_libdir, tool \\ Orchestrator.Macho.Otool) do
    app = Path.expand(app)
    fw = Path.join([app, "Contents", "Frameworks"])
    File.mkdir_p!(fw)

    copy_closure(machos(app, tool), fw, build_libdir, tool)
    Enum.each(machos(app, tool), &rewrite(&1, fw, tool))
    tool.sign_bundle(app)

    case tool.verify_bundle(app) do
      :ok ->
        gate(app, fw, tool)

      {:error, reason} ->
        IO.puts("sign_gate: FAIL — #{reason}")
        {:error, {:signature_invalid, reason}}
    end
  end
```

2. Extend the `@moduledoc` sentence about Decision C: after
"(Decision C — single `codesign --force --deep --sign -`" change
"; Phase 3 owns proper signing)" to
"), verify the signature (`codesign --verify --deep --strict` — Phase 3
invariant; Decision F: ad-hoc is sufficient, Developer ID deferred)".

`orchestrator/lib/mix/tasks/relocate.ex` — distinguish the two failures:

```elixir
  @impl true
  def run([app, build_libdir]) do
    case Orchestrator.Relocate.run(app, build_libdir) do
      :ok ->
        :ok

      {:error, {:signature_invalid, reason}} ->
        Mix.raise("bundle signature verification failed: #{reason}")

      {:error, _violations} ->
        Mix.raise("relocation gate failed: bundle is not self-contained")
    end
  end
```

- [ ] **Step 4: Run the relocate tests and verify they pass**

Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/relocate_test.exs --include macos'`
Expected: PASS — 4 tests, 0 failures (3 existing + the tamper test).

- [ ] **Step 5: Full suite + lint**

Run: `mise run test` then `mise run lint` (run `mise run fmt` first if lint complains).
Expected: all green, no warnings (the suite includes `:macos` on this host), formatted.

- [ ] **Step 6: Commit**

```bash
git add orchestrator/lib/orchestrator/macho/tool.ex orchestrator/lib/orchestrator/macho/otool.ex \
        orchestrator/lib/orchestrator/relocate.ex orchestrator/lib/mix/tasks/relocate.ex \
        orchestrator/test/orchestrator/relocate_test.exs
git commit -m "feat(phase3): verify_bundle — codesign --verify --deep --strict as a relocation invariant"
```

---

## Task 2: Second-Mac transport proof (pristine tart VM via pregate `--cmd`)

One-off validation, not permanent CI (Phase 4's end-to-end aqua install on a
clean box supersedes it — spec §3.2). Its deliverable is *evidence*, recorded in
Task 3's validation-log section.

**Files:** none modified (results recorded in Task 3).

- [ ] **Step 1: Ensure the relocated app exists in THIS working tree**

Run: `ls build/master/Emacs.app/Contents/MacOS/Emacs`

If missing, copy the Phase-2 artifact from the worktree (same content, fast):

```bash
mkdir -p build/master
cp -R /Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/modest-payne-854333/build/master/Emacs.app build/master/Emacs.app
```

If the worktree is gone, rebuild instead (~15–20 min): `mise run build && mise run relocate`.

Then sanity-check signature + self-containment on the host:

```bash
codesign --verify --deep --strict build/master/Emacs.app && echo HOST-SIG-OK
```

Expected: `HOST-SIG-OK`.

- [ ] **Step 2: Run the transport proof in a fresh macOS VM**

> **REVISED during execution (2026-06-11).** The original command asserted
> in-guest `codesign --verify --deep --strict` on the bundle and FAILED:
> "code object is not signed at all / In subcomponent: …/libexec/Emacs.pdmp".
> Systematic debugging root-caused it (validation log E7): `--deep` stores
> signatures for the two non-Mach-O nested-code files (`Emacs.pdmp`, `rcs2log`)
> in `com.apple.cs.*` xattrs, which pregate's `tar --no-xattrs` transport — and
> equally the real aqua/Go extraction — strips. Launch only consults embedded
> Mach-O signatures, so the correct post-transport assertions are: the app RUNS,
> and individual (non-main-exe) Mach-O signatures verify; the bundle deep-verify
> is captured as informational (expected fail). The command below is the
> corrected one that was actually run.

The VM (`ghcr.io/cirruslabs/macos-tahoe-base:latest`) never built the app and has
an empty Gatekeeper/cdhash cache — it is the "second arm64 Mac". pregate pipes the
tree (including `build/`, ~150 MB — expect a few extra minutes over the usual
~39 s VM-ready time) and runs the command in the guest:

```bash
pregate --macos --verbose --cmd './build/master/Emacs.app/Contents/MacOS/Emacs --batch --eval "(progn (princ emacs-version) (terpri))" && codesign --verify --strict ./build/master/Emacs.app/Contents/Frameworks/libgnutls.30.dylib && codesign --verify --strict ./build/master/Emacs.app/Contents/MacOS/bin/emacsclient && echo EMBEDDED-SIGS-OK && { codesign --verify --deep --strict ./build/master/Emacs.app 2>&1; echo deep-verify-exit=$?; ./build/master/Emacs.app/Contents/MacOS/Emacs -Q --eval "(run-with-timer 1 nil (lambda () (kill-emacs 0)))" 2>/dev/null && echo GUI-OK || echo "GUI skipped (no display)"; }'
```

Expected: pregate reports `macos PASS`; the log shows `32.0.50` (or current
master) from `--batch`, `EMBEDDED-SIGS-OK`, `deep-verify-exit=1` (the expected
E7 artifact), and `GUI-OK` (or "GUI skipped" — `--batch` is the hard gate,
exactly as in `mise run cleanroom`).

Actual result (2026-06-11): `32.0.50`, `EMBEDDED-SIGS-OK`, deep-verify FAIL on
`Emacs.pdmp` with exit 1 (expected), `GUI-OK` — **PASS**.

- [ ] **Step 3: Capture the evidence**

Save the relevant log lines (pregate prints the per-OS log path / `--verbose`
shows it inline): the codesign verify result, the printed emacs-version, the GUI
outcome. These feed Task 3 Step 1 verbatim. If the proof FAILS: stop, apply
superpowers:systematic-debugging — the failure falsifies signature *transport*,
not the quarantine findings; do not jump to Developer ID (spec §3.2).

---

## Task 3: Validation log + umbrella-spec reconcile (Decision F)

**Files:**
- Modify: `docs/superpowers/validation-log.md`
- Modify: `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`

- [ ] **Step 1: Append the Phase 3 section to `docs/superpowers/validation-log.md`**

> **REVISED during execution (2026-06-11):** the committed validation-log section
> supersedes this template — it additionally contains **E7** (the xattr-borne
> nested-code signature finding from Task 2's debugging) and the corrected
> transport-proof results; section numbering shifted accordingly (Decision F = §4,
> verify_bundle = §5). The template below is the historical baseline.

Append at the end of the file (fill the two `<RESULT: …>` slots from Task 2 Step 3
— everything else is already-validated fact):

```markdown
---

## 2026-06-11 — Phase 3: signing (validation-driven; Decision F)

Environment: macOS 26.5 (25F71) arm64, Gatekeeper "assessments enabled". Full
proofs in `~/.claude/knowledge-base/macos-gatekeeper.md`; summarized here because
the repo docs must stand alone.

### 1. Quarantine/Gatekeeper evidence — ad-hoc IS sufficient for the aqua/mise path
- **E1 — the real install path is quarantine-free:** both `mise use
  aqua:djgoku/misemacs` installs under `~/.local/share/mise/installs/` have ZERO
  `com.apple.quarantine` xattrs anywhere (`find … -exec xattr -l` → 0 hits); the
  ad-hoc apps run. Gatekeeper only assesses quarantined files ⇒ it never sees us.
- **E2 — curl sets no quarantine** (real release asset downloaded; no such xattr).
- **E3 — CLI `/usr/bin/tar` does not propagate quarantine** from a quarantined
  tarball (xattr verified on the archive; absent on extracted files). Finder/
  Archive Utility extraction untested — assumed quarantining; out of scope.
- **E4 — quarantined ad-hoc code IS blocked:** a fresh never-executed ad-hoc
  binary with `com.apple.quarantine` (0081 and Safari-style 0083) hangs/denied at
  exec; its unquarantined twin runs. So browser-download distribution would NOT
  work today — that is the Developer-ID trigger, not a v1 problem.
- **E5 — `spctl -a -t exec` "rejected" ≠ broken:** the ad-hoc Emacs.app is
  policy-rejected while `codesign --verify --deep --strict` passes; policy only
  applies to quarantined files (E1–E3).
- **E6 — Gatekeeper caches approval by cdhash:** quarantining an already-run
  binary does not block it. (Testing gotcha: GK experiments need fresh binaries.)

### 2. Transport proof — ad-hoc bundle runs on a machine that never built it
- Mechanism: pregate `--cmd` into a fresh `macos-tahoe-base` VM (empty cdhash
  cache = a true "second Mac"); tree piped in with the app at `build/master/`.
- `codesign --verify --deep --strict` in the guest: <RESULT: PASS/FAIL + line>.
- `--batch` emacs-version in the guest: <RESULT: version printed / failure>.
- GUI frame: <RESULT: OK / skipped (no display in VM)>.

### 3. Decision F — ad-hoc sufficient for v1; Developer ID + notarization DEFERRED
Grounds: E1–E5 + the transport proof. Entitlements/hardened runtime: not needed
(notarization-era concerns; ad-hoc carries neither). Revisit triggers (any one):
browser-download installation becomes a goal; a macOS release quarantines the
aqua/mise path or tightens exec policy; enterprise/MDM rejections reported.
Deferred-path seam: swap the `-` identity in `Macho.Tool.sign_bundle/1` for a
cert from CI secrets + `--options runtime` (+ entitlements if Emacs's dumper
needs them) + a `notarytool submit --wait`/`stapler staple` stage between sign
and package — gated on secret presence so contributor builds stay ad-hoc.

### 4. verify_bundle invariant (the one Phase-3 code change)
`Orchestrator.Relocate.run/3` now fails with `{:error, {:signature_invalid, …}}`
unless `codesign --verify --deep --strict` passes after the deep ad-hoc sign.
Validated: tampering a sealed Frameworks dylib post-sign → "main executable
failed strict validation / In subcomponent: …" (regression-tested with a
tamper-after-sign tool stub in `relocate_test.exs`).
```

- [ ] **Step 2: Reconcile the umbrella spec** (`docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`)

(a) **D5 row (§3):** replace the Rationale cell
"**Assumed sufficient** — existing `djgoku/misemacs` releases already install on
other Macs; optionally double-validate in Phase 3. Relocation invalidates sigs ⇒
sign last regardless" with:
"**Validated sufficient** (Phase 3, Decision F): the aqua/mise install path is
quarantine-free (curl/CLI-tar set no quarantine; real installs verified clean),
so Gatekeeper never assesses the bundle; transport-proven in a pristine VM.
Developer ID deferred (§15). Relocation invalidates sigs ⇒ sign last regardless".

(b) **§9.3 (sign):** append to the step:
"After signing, relocation verifies the signature
(`codesign --verify --deep --strict`, `Macho.Tool.verify_bundle/1`) and fails on
any invalidity — the signature is a gated invariant, not a fire-and-forget step
(Phase 3)."

(c) **§12 risk row:** replace the Mitigation cell of "Ad-hoc `.app` blocked on
other Macs (Gatekeeper/quarantine)" with:
"**RESOLVED (Phase 3, Decision F)** — the aqua/mise path never sets
`com.apple.quarantine` (validated: curl, CLI tar, real installs), so Gatekeeper
never assesses; transport-proven in a pristine VM. Quarantined ad-hoc *is*
blocked (validated), so browser-download distribution stays unsupported until
the Developer-ID enhancement (§15)".

(d) **§13 Validated list:** append:
"Gatekeeper only assesses quarantined files; curl + CLI tar set/propagate no
quarantine and real aqua/mise installs carry none ⇒ ad-hoc suffices on the
supported path; quarantined ad-hoc blocks (Dev-ID trigger); `spctl -a` rejection
of ad-hoc is expected and harmless; GK approval caches by cdhash (Phase 3, see
validation log + KB macos-gatekeeper.md)."

(e) **§13 Open list:** delete the bullet
"Ad-hoc on a *second* arm64 Mac via the aqua path — **assumed OK** (existing
`djgoku/misemacs` releases install elsewhere); optional confirm in Phase 3."

(f) **§14 Phase-3 row:** replace the '"Done" = validated by' cell with:
"quarantine/Gatekeeper evidence recorded (E1–E6); transport proof in a pristine
VM green; `verify_bundle` invariant in `Relocate` + regression test; Decision F
(Developer ID deferred with explicit triggers, §15)".

(g) **§15 Developer-ID bullet:** replace
"**Developer ID + notarization:** add behind CI secrets if Phase 3 shows ad-hoc
is insufficient; pipeline still builds without secrets for contributors." with:
"**Developer ID + notarization (Decision F: deferred — ad-hoc validated
sufficient for the quarantine-free aqua/mise path):** revisit if browser-download
installation becomes a goal, a macOS release starts quarantining/assessing the
CLI install path, or enterprise/MDM users hit rejections. Seam: swap the `-`
identity in `Macho.Tool.sign_bundle/1` for a cert from CI secrets +
`--options runtime` (+ entitlements if Emacs's dumper needs them), then a
`notarytool submit --wait` + `stapler staple` stage between sign and package —
gated on secret presence so contributor builds (no secrets) stay ad-hoc."

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/validation-log.md docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md
git commit -m "docs(phase3): Decision F + Gatekeeper evidence + transport proof; reconcile spec D5/§9.3/§12/§13/§14/§15"
```

---

## Phase 3 Definition of Done

- [ ] `mise run test` green on this macOS host (incl. `:macos` relocate tests with
      the new tamper-after-sign test) and `mise run lint` clean; ubuntu CI
      unaffected (no new `:macos`-untagged IO tests).
- [ ] `Orchestrator.Relocate.run/3` fails with `{:error, {:signature_invalid, _}}`
      on a post-sign mutation; `mix relocate` raises a distinct message for it.
- [ ] Transport proof executed in a fresh tart VM; PASS (or diagnosed failure)
      recorded in the validation log with the actual output lines.
- [ ] Validation-log Phase 3 section complete (no `<RESULT: …>` placeholders left);
      umbrella spec D5/§9.3/§12/§13/§14/§15 reconciled.
- [ ] No new CI jobs, secrets, entitlements, or notarization code (Decision F).

## Self-Review (author)

**Spec coverage:** spec §3.1 (verify_bundle callback/adapter/wiring/mix-task +
happy- and failure-path tests) → Task 1. §3.2 (transport proof, pregate reuse,
not permanent, debug-don't-pivot on failure) → Task 2. §3.3 (Decision F, triggers,
seam sketch, all six umbrella-spec touch points, validation-log section) → Task 3.
§2 evidence E1–E6 → pre-validated facts + Task 3 Step 1. KB entry — already
written during brainstorming (noted in Architecture, no task needed). Spec §5 DoD
mirrors the plan DoD one-to-one.

**Placeholder scan:** the only intentional fill-ins are Task 3's two `<RESULT: …>`
slots, which Task 2 Step 3 produces and the DoD explicitly requires resolving —
everything else (code, asserts, commands, doc edit text) is complete and verbatim.

**Type consistency:** `verify_bundle/1` returns `:ok | {:error, String.t()}` in
the callback, the adapter, and the stub; `run/3`'s widened `@spec` matches the
`{:error, {:signature_invalid, String.t()}}` produced in the body and consumed by
`Mix.Tasks.Relocate` and the new test. The tamper stub's dylib name
(`libfoo.dylib`) matches the dylib the new test compiles and the path relocation
copies it to (`Contents/Frameworks/libfoo.dylib`).
