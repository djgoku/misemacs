# Phase 3 — Signing: Design Spec

- **Date:** 2026-06-11
- **Status:** Draft for review
- **Umbrella spec:** `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md` (D5, §9.3, §12, §13, §14, §15)
- **Builds on:** Phase 2 (merged to `main` at `a34d7b4`) — relocation already deep ad-hoc signs the bundle last (`codesign --force --deep --sign -`, Decision C, in `Orchestrator.Relocate` via `Macho.Tool.sign_bundle/1`).

## 1. Scope decision (the §14 Phase-3 row, resolved)

Phase 3 is a **light validate-and-document phase, plus one small permanent gate** —
not a signing-implementation phase. The ad-hoc sign-last deliverable originally
scheduled here already shipped in Phase 2; what remained was the §12 risk
("Ad-hoc `.app` blocked on other Macs — **assumed OK**") and the Developer-ID
go/no-go. Both are now settled by evidence (§2), so Phase 3 ships:

1. **A permanent signing gate** in the relocation pipeline (`verify_bundle`, §3.1).
2. **A second-Mac transport proof** in a pristine tart VM (§3.2, one-off validation).
3. **Docs reconcile**: umbrella spec D5/§9.3/§12/§13/§14/§15 + validation-log
   Phase 3 section + **Decision F** (§3.3).

Phase 3 then flows directly into Phase 4 (package + aqua publish).

## 2. Evidence (validated 2026-06-11, macOS 26.5 arm64, Gatekeeper assessments enabled)

All facts recorded with proofs in `~/.claude/knowledge-base/macos-gatekeeper.md`.

| # | Fact | Proof |
|---|---|---|
| E1 | The real install path is **quarantine-free**: both `mise use aqua:djgoku/misemacs` installs on this machine have **zero** `com.apple.quarantine` xattrs anywhere in their trees | `find ~/.local/share/mise/installs/aqua-djgoku-misemacs -exec xattr -l` → 0 hits; apps run |
| E2 | `curl` sets **no** quarantine xattr | downloaded a real release asset; `xattr -p com.apple.quarantine` → "No such xattr" |
| E3 | CLI `/usr/bin/tar` does **not** propagate quarantine from a quarantined archive to extracted files | tarball with `0081;…` xattr (verified) → extracted file has none |
| E4 | Gatekeeper **does** block quarantined ad-hoc code: a fresh, never-executed ad-hoc binary with `com.apple.quarantine` (both `0081` and Safari-style `0083`) hangs/denied at exec | no output; SIGALRM kill after 20 s (exit 142); unquarantined twin runs |
| E5 | `spctl -a -t exec` says "rejected" for the ad-hoc `Emacs.app` even though `codesign --verify --deep --strict` passes — i.e. Gatekeeper *policy* rejects ad-hoc, but policy is only consulted for quarantined files (E1–E3 ⇒ never on our path) | spctl exit 3; codesign verify OK; `Signature=adhoc` |
| E6 | Gatekeeper approval caches by **cdhash**: quarantining an already-run binary does not block it (experiments must use fresh binaries) | previously-run `Emacs.app` copy + quarantine → still runs; fresh cdhash + same xattr → blocked |

**Conclusion (answers the brainstorm questions):**

1. **Ad-hoc is sufficient** for the supported install path (aqua/mise: curl-class
   download + tar-class extract → no quarantine → Gatekeeper never assesses).
2. The §12 "other Macs" risk is about *quarantine on the receiving Mac*, not
   signature portability — an ad-hoc signature has no trust chain to break and is
   machine-independent. The residual second-Mac question (does the signed bundle
   survive tar transport to a machine that never built it?) is closed by §3.2.
3. **Developer ID + notarization: DEFERRED** (Decision F, §3.3) — required only for
   distribution channels that quarantine (browser download of the tarball +
   Finder/Archive Utility extraction, which reportedly propagates quarantine —
   untested, deliberately out of scope).
4. **Entitlements / hardened runtime: not needed.** Both are notarization-era
   concerns; ad-hoc signing carries neither, and the Phase-2 cleanroom + E1 prove
   the app runs without them.

## 3. Design

### 3.1 Permanent signing gate — `verify_bundle/1` (the only code change)

**What:** after `sign_bundle/1` at the end of `Orchestrator.Relocate.run/3`, run
`codesign --verify --deep --strict <app>`; non-zero ⇒ relocation fails (same
failure style as the Mach-O gate). Phase 2 checked this manually; Phase 3 makes
"the shipped bundle has a valid signature" a pipeline invariant so Phase 4+
(packaging, future bundle edits) cannot silently break or reorder signing.

**Where (follows D4/§7.1 pure-core + IO-adapter):**
- `Orchestrator.Macho.Tool`: new `@callback verify_bundle(Path.t()) :: :ok | {:error, String.t()}`.
- `Orchestrator.Macho.Otool`: implement via `System.cmd("codesign", ["--verify", "--deep", "--strict", app])`,
  returning the codesign stderr in the error tuple.
- `Orchestrator.Relocate.run/3`: call after `sign_bundle`; `{:error, reason}` ⇒
  `{:error, {:signature_invalid, reason}}` (and `mix relocate` raises, as it does
  for gate violations).

**Tests:** extend the existing `@tag :macos` relocate integration test (real
fixture bundle): after `run/3`, assert the bundle passes an independent
`codesign --verify --deep --strict` and `codesign -dv` reports `Signature=adhoc`.
Failure path: corrupt a signed file in a *copy* of the fixture bundle (append a
byte to a sealed dylib **without** re-signing) and assert `verify_bundle` returns
`{:error, _}`. Pure-core is untouched (verification is inherently IO), so ubuntu
CI is unaffected (`:macos` excluded off Darwin, unchanged).

### 3.2 Second-Mac transport proof (one-off validation, recorded — not permanent CI)

**What:** prove the ad-hoc-signed relocated `Emacs.app`, transported as a
tarball, runs on a machine that never built it (closes §12's "assumed OK" with
first-party evidence; the existing-releases anecdote becomes a recorded fact).

**How:** host-orchestrated, reusing the existing tart/pregate machinery (no
nested VM): `tar czf` the relocated `build/master/Emacs.app` on the host → clone
a fresh macOS VM (`tart clone` from the same base pregate uses; **verify the
clone** per the tart KB gotcha) → copy the tarball in → extract with
`/usr/bin/tar` → `codesign --verify --deep --strict` → `--batch` smoke
(+ GUI frame best-effort). A fresh VM clone is a distinct machine identity with
an empty Gatekeeper/cdhash cache (E6 makes that property matter), which is
exactly what "a 2nd arm64 Mac that never built it" requires. The tarball is a
*transport* tarball — the contractual asset layout stays Phase 4.

**Why not permanent:** Phase 4's DoD already includes the strictly-stronger
end-to-end check (`mise use aqua:djgoku/misemacs@<tag>` on a clean box).
Pregate stays as-is (it proves buildability + self-containment, not transport).
This is a validation task whose *output* is a validation-log entry.

**If it fails:** that falsifies signature-transport, not quarantine behavior —
debug before touching the Developer-ID question (per systematic-debugging).

> **Execution note (2026-06-11):** exactly this branch occurred. The in-guest
> *bundle* deep-verify failed; debugging root-caused it to xattr-borne signatures
> on the two non-Mach-O nested-code files (`Emacs.pdmp`, `rcs2log`) that no
> tar/Go-extract transport preserves (validation log **E7**). The proof's
> assertions were corrected to what the channel actually guarantees — app runs +
> individual Mach-O signatures verify — and **passed** in the pristine VM
> (`32.0.50`, `EMBEDDED-SIGS-OK`, `GUI-OK`). Bundle-level verification is
> build-time-only (`verify_bundle`); Decision F stands unchanged.

### 3.3 Decision F + docs reconcile

**Decision F — ad-hoc signing is sufficient for v1; Developer ID + notarization
deferred.** Grounds: E1–E5. Revisit triggers (any one):
- We want **browser-download** installation (quarantined path) to work.
- A macOS release starts quarantining/assessing the aqua/mise path (e.g. CLI
  tools begin setting quarantine, or exec-path policy tightens).
- Enterprise/MDM users report Gatekeeper or endpoint-security rejections.

**Deferred-path sketch (documented in umbrella §15, not built):** the seam is
already one call — `Macho.Tool.sign_bundle/1`. A Developer-ID variant replaces
the `-` identity with a cert from CI secrets, adds `--options runtime` (+
entitlements if Emacs's dumper needs them — investigate then, not now), then
`notarytool submit --wait` + `stapler staple` as a new bash pipeline stage
between sign and package. Gated on secret presence so contributor builds
(no secrets) still produce ad-hoc bundles — the pipeline must never *require*
secrets. None of this is implemented in v1.

**Reconcile (same files Phase 2's Task 6 touched):**
- Umbrella D5: "**Assumed sufficient**" → validated (point to Decision F + KB).
- §9.3: add the `verify_bundle` invariant to the sign step.
- §12 risk row: "Assumed OK" → resolved with evidence (E1–E5 + transport proof).
- §13: move "ad-hoc on a second Mac via the aqua path" from Open → Validated.
- §14 Phase-3 row: "assumed good / optionally double-validate" → actual DoD (§5).
- §15 Developer-ID bullet: replace "if Phase 3 shows ad-hoc is insufficient" with
  Decision F triggers + the sketch above.
- `docs/superpowers/validation-log.md`: new "2026-06-11 — Phase 3" section (E1–E6,
  spctl/codesign outputs, the transport-proof result, Decision F).

## 4. Approaches considered

- **A. Validate-and-document + permanent verify gate (chosen).** Matches the
  evidence; smallest surface; Phase 3 stays light and unblocks Phase 4.
- **B. Full Developer ID + notarization now.** Rejected: solves a problem the
  supported install path provably doesn't have; costs an Apple Developer
  account, CI secret management, hardened-runtime/entitlements risk on Emacs's
  unexec/pdmp machinery, and notarization latency per release.
- **C. Build the flag-gated Developer-ID code path now, unused.** Rejected:
  untestable without an account/secrets (violates validate-don't-assume — we'd
  ship code whose behavior we cannot run), and YAGNI; the one-call seam +
  documented sketch (§3.3) preserves all the optionality at zero code cost.

## 5. Definition of Done

- [ ] `verify_bundle/1` behaviour + adapter + Relocate wiring; failure path covered;
      `mise run test` green on macOS (incl. `:macos`) and ubuntu CI unaffected.
- [ ] Transport proof executed in a fresh tart VM; result (pass, or diagnosed
      failure) recorded in the validation log.
- [ ] Decision F + E1–E6 in the validation log; umbrella spec reconciled
      (D5, §9.3, §12, §13, §14, §15); knowledge base entry exists
      (`macos-gatekeeper.md` — already written).
- [ ] No new CI jobs, no secrets, no entitlements, no notarization code.
