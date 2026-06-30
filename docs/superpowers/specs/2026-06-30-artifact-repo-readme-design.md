# Design — artifact-repo README generator

*2026-06-30. Branch: `per-channel-artifact-repos`. Status: design — pending user review.*

## 1. Problem

Per-channel artifact repos (`djgoku/misemacs-emacs-<channel>`) are write-only release buckets a
human never edits. Today they need *some* initial commit (an empty repo 422s on the first
`gh release create`), currently a throwaway one-line README. A visitor landing on
`djgoku/misemacs-emacs-31` has no idea what it is, how to install from it, where the built
artifact lives, or that the source/issues live elsewhere. We want a real, channel-specific
`README.org` that doubles as the required bootstrap commit.

## 2. Goals / non-goals

**Goals**
- Each artifact repo has a clear `README.org`: what it is, how to install (preference-ordered),
  what each release contains, how it's verified, how versioning works, and a pointer back to the
  source repo.
- The README is **per-channel and version-agnostic** — it never names a specific dated build, so
  it never goes stale and needs no CI upkeep.
- Generated from one source of truth (the orchestrator), keyed off `versions.toml`, so adding a
  channel produces the right README with no hand-editing.
- It serves as the artifact repo's **initial commit** (replacing the throwaway README), resolving
  the empty-repo 422.

**Non-goals**
- CI-regenerating the README per publish (rejected — version-agnostic static doc, YAGNI).
- Documenting a specific version/date in the README (that's the live Releases page's job).
- Any change to the publish/finalize/registry pipeline.

## 3. Design

### 3.1 Generator — `mix release.artifact_readme`
A new mix task, sibling to `Mix.Tasks.Release.Manifest`, under
`orchestrator/lib/mix/tasks/release.artifact_readme.ex`:

```
mix release.artifact_readme --version <name> [--artifact-base <base>] [--root ..]
```

- Reads `channel` and `ref` for `<name>` from `versions.toml` (the same `Toml.decode` +
  `get_in(map, ["versions", name])` lookup `release.manifest` uses).
- Derives the repo via `Orchestrator.Naming.artifact_repo(base, channel)` (`--artifact-base`
  defaults to env `MISEMACS_ARTIFACT_BASE`, blank-safe, then `djgoku/misemacs`).
- Prints a complete `README.org` to **stdout** (no file writes; the caller redirects).
- Pure aside from reading `versions.toml`; network-free.

Keying on `--version` (not `--channel`) matches `release.manifest` and yields `ref` for free;
channel↔version is 1:1 so the README is effectively per-channel/per-repo.

### 3.2 Content (channel-filled, date-free)
Sections, in order — substituted tokens shown as `<…>`:

1. **What this is.** "Auto-published release bucket for the `<channel>` channel of misemacs —
   relocatable `Emacs.app` for macOS, built from the `=<ref>=` ref of emacsmirror/emacs by the
   pipeline in [[https://github.com/djgoku/misemacs][djgoku/misemacs]]. Nothing here is
   hand-edited."
2. **Install** — three methods, preference order:
   - **(a) aqua registry (preferred; TBD).** Once the package is in the upstream aqua-registry,
     `mise use aqua:<repo>@latest` is zero-config. Marked *coming soon / not yet submitted*.
   - **(b) `MISE_AQUA_REGISTRIES` (interim).** `MISE_AQUA_REGISTRIES=<raw url to misemacs
     aqua/registry.yaml> mise use aqua:<repo>@latest` — versions are the clean stripped date
     (e.g. `2026-06-30`).
   - **(c) `github:` backend (no registry).** `mise use github:<repo>@latest` — needs no registry
     config; **caveat (validated):** its version string is the *full tag*
     (`emacs-<channel>-YYYY-MM-DD`), not the stripped date.
3. **What's in each release.** The three assets: `misemacs-<tag>-macos-arm64.tar.gz` (the
   relocatable `Emacs.app` + bundled enchant), `SHASUMS256.txt`, and `build-manifest.json`
   (records the upstream sha + input fingerprint for that build).
4. **Verification.** mise verifies GitHub's per-asset digest automatically on both the aqua and
   `github:` paths; `SHASUMS256.txt` is attached for manual `shasum -c` checks.
5. **Versioning.** Tags are CalVer `emacs-<channel>-YYYY-MM-DD` (`.N` suffix on same-day
   rebuilds). `@latest` rolls this channel independently and is marker-independent
   (`version_source: github_tag` — newest tag wins, not the GitHub "Latest" badge).
6. **Source & issues.** Prominent: "This is a generated artifact bucket — **do not open issues or
   PRs here.** Source, build system, and docs live in
   [[https://github.com/djgoku/misemacs][djgoku/misemacs]]."

`README.org` (Org, not Markdown) — matches the main repo and renders on GitHub. Channel "meaning"
is conveyed via the `=<ref>=` line (data-driven), not per-channel editorial prose.

### 3.3 Bootstrap integration
Replaces the throwaway README as the artifact repo's initial commit. Add-a-version flow:

```sh
gh repo create djgoku/misemacs-emacs-<channel> --public
mise run artifact-readme -- --version <name> > /tmp/r.org
gh api repos/djgoku/misemacs-emacs-<channel>/contents/README.org -X PUT \
  -f message="init: artifact repo" -f content="$(base64 -i /tmp/r.org)"
```

A `mise` task alias `artifact-readme` wraps `cd orchestrator && mix release.artifact_readme`
(mirroring the existing `manifest`/`decide`/`finalize` task wrappers).

### 3.4 Tests
`orchestrator/test/mix/tasks/release_artifact_readme_test.exs`, string-contract style (like
`registry_contract_test`): generate for `master` and `emacs-31` (via `--root ..` against the real
`versions.toml`) and assert each output contains:
- the correct artifact repo (`djgoku/misemacs-emacs-master` / `…-emacs-31`),
- the channel and its `ref`,
- all three install invocations (aqua-registry, `MISE_AQUA_REGISTRIES`, `github:`),
- the "do not open issues/PRs here" source pointer,
- and **no literal date** (`refute =~ ~r/\d{4}-\d{2}-\d{2}/`) — proving it's version-agnostic.

### 3.5 Docs
Update the main `README.org` add-a-version step and the per-channel-artifact-repos spec §4.10 to
use the generator (replacing the `--add-readme` one-liner).

## 4. Definition of Done
- `mix release.artifact_readme --version <name>` prints a channel-filled `README.org`; `mise run
  artifact-readme` wrapper works.
- Contract test green (both channels, all three install methods, source pointer, no date).
- `cd orchestrator && mix test` + `mix compile --warnings-as-errors` clean.
- Main README + spec §4.10 updated to the generator-based bootstrap.
- Manual check: generated README PUT to a lab artifact repo renders correctly on GitHub.

## 5. Open follow-ups (out of scope)
- Submitting the packages to the upstream aqua-registry (turns install method (a) from TBD to
  zero-config). Tracked separately.
