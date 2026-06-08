# Validation Log

## 2026-06-08 — Phase 0 / Task 10: mise pixi-plugin path

Environment: macOS arm64, mise 2026.6.1, pixi 0.70.2 (installed via mise). Probes ran in a
throwaway temp dir; pixi invoked ephemerally via `mise x pixi@latest -- …` (no change to the
global mise config). The `mise-backend-pixi` plugin is installed globally as `vfox-pixi`.

### 1. Backend plugin name & prefix — CORRECTION to the plan/spec
- Installing the backend plugin as **`pixi`** (the plan's Task 10 Step 1 / spec §6.1)
  **conflicts with the `pixi` tool** and breaks pixi resolution entirely: `pixi is not a
  valid shim`, and the plugin's own hook fails with `sh: pixi: command not found`.
- Install it as **`vfox-pixi`** (the README default): `mise plugin install vfox-pixi
  https://github.com/esteve/mise-backend-pixi`. After that the `pixi` tool resolves again
  and the backend prefix is **`vfox-pixi:`** (e.g. `mise use vfox-pixi:<tool>`).
- **Action:** fix spec §6.1 — the `[plugins]` entry must be `vfox-pixi = "…"`, not
  `pixi = "…"`; any ad-hoc conda CLI uses the `vfox-pixi:` prefix.

### 2. Backend tool install (`mise use vfox-pixi:<tool>`)
- The backend's hooks shell out to `pixi search` / `pixi global install`, so **pixi must be
  genuinely on PATH** when mise runs the plugin. Under ephemeral `mise x pixi`, the nested
  plugin subprocess did not see pixi. So the backend works once **pixi is an installed/active
  mise tool** (Phase 1 pins pixi in the repo `mise.toml`). Prefix is settled; full
  install-via-backend not exercised here.
- This path is **secondary**: build/runtime C libs use the pixi **PROJECT** (pixi.toml +
  pixi.lock), not the per-tool backend.

### 3. Reproducibility (D7) — CONFIRMED
- A pixi **project** locks the **full transitive closure** in `pixi.lock`. `pixi add gnutls
  libxml2 jansson` (3 top-level deps) produced a `pixi.lock` with **36** conda packages,
  including gnutls's transitive deps **gmp, libtasn1, nettle, p11-kit** (never explicitly
  added). → D7 (bit-reproducible build inputs via pixi) holds.
- `pixi init` on macOS arm64 defaults to `platforms = ["osx-arm64"]` — no `--platform` flag
  needed on the host.

### 4. tree-sitter (v1-optional dep) — KEEP; package name is `libtree-sitter`
- conda-forge has **no** package named `tree-sitter` (`pixi add tree-sitter` → "No
  candidates found").
- The C library is **`libtree-sitter`** (conda-forge, v0.26.9). → KEEP `--with-tree-sitter`
  in v1, sourcing **`libtree-sitter`** in `pixi.toml`. Confirm headers (`tree_sitter.h`) are
  usable at `./configure` time in Phase 1 (conda-forge sometimes splits dev headers).

### Decisions for Phase 1
- Build libs via a pixi **PROJECT** (`pixi.toml` + `pixi.lock`); transitive lock is real (D7 ✓).
- mise-backend-pixi plugin name = **`vfox-pixi`** (NOT `pixi`); backend prefix = `vfox-pixi:`.
  Fix spec §6.1.
- tree-sitter dep in `pixi.toml` = **`libtree-sitter`**; keep `--with-tree-sitter`.
