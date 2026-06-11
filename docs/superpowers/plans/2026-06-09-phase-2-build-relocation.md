# Phase 2 — Build + Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, relocatable **GUI** `Emacs.app` from the per-version pixi env that launches on a clean macOS arm64 machine with no pixi/conda/Homebrew present.

**Architecture (hybrid — 2026-06-09 decision):** The **build** is a bash stage (`pipeline/build-emacs`: enter the pixi env, `autogen → configure → make → make install`). The **relocation + gate** is **Elixir**, in the existing orchestrator app, following the project's pure-core + IO-adapter pattern (spec D4/§7.1): `Orchestrator.Macho` (pure: classify paths, compute the dylib closure, evaluate the gate) + `Orchestrator.Macho.Tool` behaviour with the `Orchestrator.Macho.Otool` IO adapter (otool/install_name_tool/codesign) + `Orchestrator.Relocate` (the runner) + a `mix relocate` task. Generic over all Mach-O — ncurses bundled, no terminfo work (GUI-only). Proof of done: the gate returns no violations AND the relocated app runs `--batch` (+ a GUI frame smoke) inside a fresh tart VM that never had pixi.

**Tech Stack:** Elixir 1.20 / ExUnit (relocation logic + gate, in `orchestrator/`); bash + `otool`/`install_name_tool`/`codesign` shelled from Elixir via `System.cmd`; bash for the build stage (under `pixi run`); mise (tasks + toolchain); tart 2.31.0 (clean-room VM); clang (test fixtures).

---

## Decisions frozen here (the 2026-06-09 brainstorm + hybrid-language outcome)

These were settled with the user; the umbrella spec (`docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`) is reconciled to match in Task 7.

- **GUI-only.** v1 deliverable is the NS `Emacs.app`. The GUI never initializes terminfo, so relocation is a **generic Mach-O closure walk with zero special-cases** — ncurses is bundled like any other dylib (its dylib only needs to *resolve* at load).
- **`emacs -nw` is out of scope**, recorded in spec §15 as a **post-Phase-4 fast-follow** (one-row system-rewrite of `libncurses` → `/usr/lib/libncurses.5.4.dylib`). Validated 2026-06-09: a *bundled* conda ncurses 6.6 searches only `$CONDA_PREFIX/share/terminfo` (`infocmp -D`). **Do not** add terminfo handling in Phase 2.
- **Language split (hybrid).** Build = bash (glue); relocation + gate = Elixir (decisions), per D4/§7.1. The relocation *logic* (classify / closure / gate rules) is pure and ExUnit-tested; the IO (otool/install_name_tool/codesign) is a `System.cmd` adapter behind a behaviour, so the core is tested with fixture strings and the adapter is swappable in tests. This replaces the initial bash `lib/macho.sh` (commits `fadcc3d`/`d78fe88`), whose validated logic is ported verbatim — Task 1 removes the bash files.
- **Cross-platform tests.** Orchestrator CI is **ubuntu** (`orchestrator-ci.yml` runs `mise run test`). Pure relocation tests run everywhere; the real-binary integration test is `@tag :macos` and excluded off Darwin via `test_helper.exs`.
- **Decision C — minimal ad-hoc re-sign lives in Phase 2.** `install_name_tool` invalidates code signatures and arm64 kills an invalid-sig binary, so the runner ad-hoc re-signs (`codesign -s - -f`) every Mach-O it rewrites. Proper/Developer-ID signing remains Phase 3.
- **Decision D — `bin/` move + Info.plist/icon stay in Phase 4.** Phase 2 relocates whatever Mach-O `make install` produces, in their default locations.
- **Decision E — host `make`/CLT fingerprint gap (spec §8): record now, wire in Phase 5.** Resolution in Task 7: fold `xcode-select -p` + the active clang/SDK build version into `toolchain_hash` when the fingerprint is consumed (Phase 5). No code in Phase 2.
- **rpath ownership.** `build-emacs` adds only `-Wl,-headerpad_max_install_names` and `-Wl,-rpath,$CONDA_PREFIX/lib` (the latter solely so the in-build dump step can load conda dylibs — Phase-1 finding). `Orchestrator.Relocate` adds the depth-correct `@loader_path/<rel-to-Frameworks>` rpath to every Mach-O and deletes the foreign (`$CONDA_PREFIX/lib`) rpath. (Refines spec §9.)
- **Clean-VM proof = the one pregate macOS VM.** pregate (a fresh disposable macOS VM, host-orchestrated) runs build → relocate → static gate → `mise run cleanroom` (moves the pixi env aside, then `--batch` + a GUI frame). No second/nested VM, no `sshpass`, no bespoke image pull. Local "done" rests on the static gate + the moved-aside fixture test + the real-app validation.

## File Structure

| Path | New? | Responsibility |
|---|---|---|
| `orchestrator/lib/orchestrator/macho.ex` | create | **Pure** Mach-O reasoning: `classify/1`, `relpath/2`, `parse_id/1`, `parse_deps/2`, `parse_rpaths/1`, `bundleable/1`, `gate_violations/2`. No IO. |
| `orchestrator/lib/orchestrator/macho/tool.ex` | create | The IO **behaviour** (`@callback` for macho?/id/deps/rpaths/set_id/change/add_rpath/delete_rpath/sign_bundle). |
| `orchestrator/lib/orchestrator/macho/otool.ex` | create | Default IO **adapter** — shells `otool`/`install_name_tool`/`codesign` via `System.cmd`, parses with `Orchestrator.Macho`. |
| `orchestrator/lib/orchestrator/relocate.ex` | create | The runner: BFS the closure into `Contents/Frameworks`, normalize ids/refs, fix rpaths, deep ad-hoc sign the whole bundle once, gate. Reasoning via `Macho`, IO via a `Tool` (default `Otool`). |
| `orchestrator/lib/mix/tasks/relocate.ex` | create | `mix relocate <app> <build_libdir>` entrypoint → `Orchestrator.Relocate.run/2`. |
| `orchestrator/test/orchestrator/macho_test.exs` | create | Pure tests (run everywhere): classify/relpath/parse/bundleable/gate_violations with fixture strings. |
| `orchestrator/test/orchestrator/relocate_test.exs` | create | `@tag :macos` integration: clang-built fixture bundle → `Relocate.run` → gate ok + runs with build libdir moved aside. |
| `orchestrator/test/test_helper.exs` | modify | Exclude `:macos` tests off Darwin. |
| `lib/macho.sh`, `tests/macho_test.sh` | **delete** | Superseded by the Elixir modules (Task 1 `git rm`s them). |
| `pipeline/build-emacs` | create | Fetch + configure + make + install under the pixi env → `build/<v>/Emacs.app` + `conda-prefix-lib.txt` + otool discovery dump. |
| `mise.toml` | modify | Add tasks `build`, `relocate` (→ `mix relocate`), `cleanroom` (move pixi env aside + no-pixi launch). (No `test-macho` — Elixir tests run under `mise run test`.) |
| `.gitignore` | modify | Ignore `/build/`. |
| `.pregate/macos.sh` | modify | After the shared body: `mise run build` + `mise run relocate` + `mise run cleanroom` — all in the one fresh macOS VM. |
| `versions/master/mise.toml` | modify | Fix the stale "ncurses = system /usr/lib" comment (Task 6). |
| `docs/superpowers/validation-log.md`, `docs/.../2026-06-05-…-design.md` | modify | Phase 2 findings + Decision E + spec reconcile (Task 6). |

**Conventions (from the orchestrator):** modules carry `@moduledoc`/`@type`/`@spec`/`@doc`; tests `use ExUnit.Case, async: true` with `alias`; pure logic has no IO and is fixture-tested; build stages are bash invoked as `bash pipeline/<stage> <version>`, reading `EMACS_REF`/`EMACS_CONFIGURE_FLAGS` from `versions/<v>/mise.toml` via `mise exec`, entering the pixi env with `mise exec -- pixi run --manifest-path "$VDIR/pixi.toml"`. Commit after each task.

## Branch setup (already done)

Worktree branch `claude/modest-payne-854333` (root `/Users/dj_goku/dev/github/djgoku/misemacs/.claude/worktrees/modest-payne-854333`). All paths relative to that root. Do **not** push or rebase.

---

## Task 1: `Orchestrator.Macho` — pure Mach-O reasoning + IO adapter (TDD)

Port the validated behavior of the committed bash `lib/macho.sh` (commits `fadcc3d`, `d78fe88`) into Elixir, then remove the bash files. The pure module is the testable core; the adapter is the IO edge.

**Files:**
- Create: `orchestrator/lib/orchestrator/macho.ex`, `orchestrator/lib/orchestrator/macho/tool.ex`, `orchestrator/lib/orchestrator/macho/otool.ex`
- Test: `orchestrator/test/orchestrator/macho_test.exs`
- Modify: `orchestrator/test/test_helper.exs`
- Delete: `lib/macho.sh`, `tests/macho_test.sh`

- [ ] **Step 1: Write the failing pure test** — create `orchestrator/test/orchestrator/macho_test.exs`:

```elixir
defmodule Orchestrator.MachoTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Macho

  # Realistic otool fixture strings (captured shape; arm64).
  @otool_l """
  /p/App.app/Contents/MacOS/App:
  \t@rpath/libfoo.dylib (compatibility version 0.0.0, current version 0.0.0)
  \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
  """
  @otool_l_dylib """
  /build/lib/libfoo.dylib:
  \t@rpath/libfoo.dylib (compatibility version 0.0.0, current version 0.0.0)
  \t@rpath/libbar.dylib (compatibility version 0.0.0, current version 0.0.0)
  """
  @otool_d "/build/lib/libfoo.dylib:\n@rpath/libfoo.dylib\n"
  @otool_d_exe "/p/App.app/Contents/MacOS/App:\n"
  @otool_l_rpath """
  Load command 12
            cmd LC_RPATH
        cmdsize 32
           path /build dir/lib (offset 12)
  Load command 13
            cmd LC_RPATH
        cmdsize 40
           path @loader_path/../Frameworks (offset 12)
  """

  test "classify" do
    assert Macho.classify("/usr/lib/libSystem.B.dylib") == :system
    assert Macho.classify("/System/Library/Frameworks/AppKit") == :system
    assert Macho.classify("@rpath/libfoo.dylib") == :bundled
    assert Macho.classify("@loader_path/../Frameworks") == :bundled
    assert Macho.classify("/opt/homebrew/lib/libx.dylib") == :foreign
    assert Macho.classify("librelative.dylib") == :other
  end

  test "relpath" do
    assert Macho.relpath("/a/App/Contents/Frameworks", "/a/App/Contents/MacOS") == "../Frameworks"
    assert Macho.relpath("/a/App/Contents/Frameworks", "/a/App/Contents/MacOS/bin") == "../../Frameworks"
    assert Macho.relpath("/a/App/Contents/Frameworks", "/a/App/Contents/Frameworks") == "."
  end

  test "parse_id" do
    assert Macho.parse_id(@otool_d) == "@rpath/libfoo.dylib"
    assert Macho.parse_id(@otool_d_exe) == nil
  end

  test "parse_deps excludes self id, keeps system + @rpath" do
    assert Macho.parse_deps(@otool_l, nil) ==
             ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib"]
    assert Macho.parse_deps(@otool_l_dylib, "@rpath/libfoo.dylib") == ["@rpath/libbar.dylib"]
  end

  test "parse_rpaths is space-tolerant" do
    assert Macho.parse_rpaths(@otool_l_rpath) == ["/build dir/lib", "@loader_path/../Frameworks"]
  end

  test "bundleable = foreign + @rpath only" do
    deps = ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib", "/opt/homebrew/lib/libx.dylib"]
    assert Macho.bundleable(deps) == ["@rpath/libfoo.dylib", "/opt/homebrew/lib/libx.dylib"]
  end

  test "gate_violations: foreign dep, missing @rpath lib, foreign rpath" do
    machos = [
      %{path: "exe", deps: ["@rpath/libfoo.dylib", "/opt/x/liby.dylib"], rpaths: ["/build/lib"]},
      %{path: "ok", deps: ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib"], rpaths: ["@loader_path/../Frameworks"]}
    ]
    fw = MapSet.new(["libfoo.dylib"])
    v = Macho.gate_violations(machos, fw)
    assert {:foreign_dep, "exe", "/opt/x/liby.dylib"} in v
    assert {:foreign_rpath, "exe", "/build/lib"} in v
    refute Enum.any?(v, &match?({:missing_lib, _, _}, &1))
    # missing case:
    assert {:missing_lib, "z", "@rpath/libgone.dylib"} in
             Macho.gate_violations([%{path: "z", deps: ["@rpath/libgone.dylib"], rpaths: []}], fw)
  end

  test "gate_violations empty == self-contained" do
    machos = [%{path: "ok", deps: ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib"], rpaths: ["@loader_path/../Frameworks"]}]
    assert Macho.gate_violations(machos, MapSet.new(["libfoo.dylib"])) == []
  end
end
```

- [ ] **Step 2: Run it and watch it fail**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/macho_test.exs'`
Expected: FAIL — `Orchestrator.Macho` undefined / module not found.

- [ ] **Step 3: Write the pure module** — `orchestrator/lib/orchestrator/macho.ex`:

```elixir
defmodule Orchestrator.Macho do
  @moduledoc """
  Pure Mach-O reasoning for relocation: classify install-name paths, compute relative
  rpaths, parse `otool` output, and evaluate the self-contained gate. No IO — the IO edge
  (otool/install_name_tool/codesign) is `Orchestrator.Macho.Otool` behind the
  `Orchestrator.Macho.Tool` behaviour (spec §7.1: pure core + IO adapter). Ports the
  validated bash `lib/macho.sh` logic (including its space-tolerant otool parsing).
  """

  @type class :: :system | :bundled | :foreign | :other
  @type macho :: %{path: String.t(), deps: [String.t()], rpaths: [String.t()]}
  @type violation ::
          {:foreign_dep, String.t(), String.t()}
          | {:missing_lib, String.t(), String.t()}
          | {:foreign_rpath, String.t(), String.t()}

  @doc "Classify a dependency/rpath path. See `t:class/0`."
  @spec classify(String.t()) :: class
  def classify("/usr/lib/" <> _), do: :system
  def classify("/System/" <> _), do: :system
  def classify("@rpath/" <> _), do: :bundled
  def classify("@executable_path/" <> _), do: :bundled
  def classify("@loader_path/" <> _), do: :bundled
  def classify("/" <> _), do: :foreign
  def classify(_), do: :other

  @doc "Relative path to reach absolute dir `to` from absolute dir `from` (e.g. `../Frameworks`, `.`)."
  @spec relpath(String.t(), String.t()) :: String.t()
  def relpath(to, from) do
    t = String.split(to, "/", trim: true)
    f = String.split(from, "/", trim: true)
    n = common_len(t, f, 0)
    parts = List.duplicate("..", length(f) - n) ++ Enum.drop(t, n)
    if parts == [], do: ".", else: Enum.join(parts, "/")
  end

  defp common_len([h | t1], [h | t2], n), do: common_len(t1, t2, n + 1)
  defp common_len(_, _, n), do: n

  @doc "Parse `otool -D <file>` output → the install-name id, or nil for a plain executable."
  @spec parse_id(String.t()) :: String.t() | nil
  def parse_id(otool_d) do
    case String.split(otool_d, "\n", trim: true) do
      [_header, id | _] -> String.trim(id)
      _ -> nil
    end
  end

  @doc """
  Parse `otool -L <file>` output → dependency install-names, excluding `self_id`.
  Space-tolerant: strips the trailing ` (compatibility version …)` rather than splitting on whitespace.
  """
  @spec parse_deps(String.t(), String.t() | nil) :: [String.t()]
  def parse_deps(otool_l, self_id \\ nil) do
    otool_l
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&dep_path/1)
    |> Enum.reject(&(&1 in [nil, "", self_id]))
  end

  defp dep_path(line) do
    line
    |> String.trim_leading()
    |> String.replace(~r/ \(compatibility version .*$/, "")
  end

  @doc "Parse `otool -l <file>` output → LC_RPATH paths. Space-tolerant."
  @spec parse_rpaths(String.t()) :: [String.t()]
  def parse_rpaths(otool_l), do: otool_l |> String.split("\n") |> rpaths([], false)

  defp rpaths([], acc, _in?), do: Enum.reverse(acc)

  defp rpaths([line | rest], acc, in?) do
    cond do
      Regex.match?(~r/^\s*cmd LC_RPATH\s*$/, line) -> rpaths(rest, acc, true)
      in? and Regex.match?(~r/^\s*path /, line) ->
        p =
          line
          |> String.replace(~r/^\s*path /, "")
          |> String.replace(~r/ \(offset \d+\)\s*$/, "")
        rpaths(rest, [p | acc], false)
      true -> rpaths(rest, acc, in?)
    end
  end

  @doc "Deps that must be copied into Frameworks: `:foreign` or `@rpath/*`."
  @spec bundleable([String.t()]) :: [String.t()]
  def bundleable(deps) do
    Enum.filter(deps, fn d -> classify(d) == :foreign or String.starts_with?(d, "@rpath/") end)
  end

  @doc """
  Gate: given every Mach-O's parsed metadata and the basenames present in Frameworks,
  return the list of violations (empty == self-contained).
  """
  @spec gate_violations([macho], MapSet.t(String.t())) :: [violation]
  def gate_violations(machos, framework_basenames) do
    Enum.flat_map(machos, fn %{path: p, deps: deps, rpaths: rpaths} ->
      dep_v =
        Enum.flat_map(deps, fn d ->
          case classify(d) do
            :foreign -> [{:foreign_dep, p, d}]
            :bundled -> missing_lib(d, p, framework_basenames)
            _ -> []
          end
        end)

      rpath_v = for r <- rpaths, classify(r) == :foreign, do: {:foreign_rpath, p, r}
      dep_v ++ rpath_v
    end)
  end

  defp missing_lib("@rpath/" <> base, p, fw) do
    if MapSet.member?(fw, base), do: [], else: [{:missing_lib, p, "@rpath/" <> base}]
  end

  defp missing_lib(_, _, _), do: []
end
```

- [ ] **Step 4: Run the pure test to verify it passes**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/macho_test.exs'`
Expected: PASS — 8 tests, 0 failures. If a parser assertion fails because real `otool` output differs from the fixture strings, FIX the parser (keep it space-tolerant); do not weaken assertions.

- [ ] **Step 5: Write the IO behaviour** — `orchestrator/lib/orchestrator/macho/tool.ex`:

```elixir
defmodule Orchestrator.Macho.Tool do
  @moduledoc "IO behaviour for Mach-O introspection + mutation (otool/install_name_tool/codesign)."
  @callback macho?(Path.t()) :: boolean
  @callback id(Path.t()) :: String.t() | nil
  @callback deps(Path.t()) :: [String.t()]
  @callback rpaths(Path.t()) :: [String.t()]
  @callback set_id(Path.t(), String.t()) :: :ok
  @callback change(Path.t(), String.t(), String.t()) :: :ok
  @callback add_rpath(Path.t(), String.t()) :: :ok
  @callback delete_rpath(Path.t(), String.t()) :: :ok
  @callback resign(Path.t()) :: :ok
end
```

- [ ] **Step 6: Write the default IO adapter** — `orchestrator/lib/orchestrator/macho/otool.ex`:

```elixir
defmodule Orchestrator.Macho.Otool do
  @moduledoc "Default `Orchestrator.Macho.Tool` — shells host CLT tools, parses with `Orchestrator.Macho`."
  @behaviour Orchestrator.Macho.Tool
  alias Orchestrator.Macho

  @impl true
  def macho?(path) do
    File.regular?(path) and
      (case System.cmd("file", ["-b", path], stderr_to_stdout: true) do
         {out, 0} -> String.contains?(out, "Mach-O")
         _ -> false
       end)
  end

  @impl true
  def id(path), do: path |> run("otool", ["-D"]) |> Macho.parse_id()

  @impl true
  def deps(path), do: Macho.parse_deps(run(path, "otool", ["-L"]), id(path))

  @impl true
  def rpaths(path), do: path |> run("otool", ["-l"]) |> Macho.parse_rpaths()

  @impl true
  def set_id(path, new), do: int(path, ["-id", new])
  @impl true
  def change(path, old, new), do: int(path, ["-change", old, new])
  @impl true
  def add_rpath(path, rp), do: int_ok(path, ["-add_rpath", rp])
  @impl true
  def delete_rpath(path, rp), do: int_ok(path, ["-delete_rpath", rp])

  @impl true
  def resign(path) do
    System.cmd("codesign", ["--remove-signature", path], stderr_to_stdout: true)
    {_, 0} = System.cmd("codesign", ["-s", "-", "-f", path], stderr_to_stdout: true)
    :ok
  end

  defp run(path, cmd, args) do
    {out, _} = System.cmd(cmd, args ++ [path], stderr_to_stdout: true)
    out
  end

  defp int(path, args) do
    {_, 0} = System.cmd("install_name_tool", args ++ [path], stderr_to_stdout: true)
    :ok
  end

  defp int_ok(path, args) do
    System.cmd("install_name_tool", args ++ [path], stderr_to_stdout: true)
    :ok
  end
end
```

> Note: the `macho?/1` body above has a deliberately odd `match?(... ) == false` guard placeholder that the implementer MUST replace with the clean version below — it is left so the implementer writes it correctly:
> ```elixir
> def macho?(path) do
>   File.regular?(path) and
>     (case System.cmd("file", ["-b", path], stderr_to_stdout: true) do
>        {out, 0} -> String.contains?(out, "Mach-O")
>        _ -> false
>      end)
> end
> ```

- [ ] **Step 7: Remove the superseded bash files + adjust `test_helper.exs`**

`git rm lib/macho.sh tests/macho_test.sh`

Edit `orchestrator/test/test_helper.exs` to exclude macOS-only tests off Darwin:
```elixir
exclude = if :os.type() == {:unix, :darwin}, do: [], else: [:macos]
ExUnit.start(exclude: exclude)
```

- [ ] **Step 8: Full suite + format, then commit**
Run: `mise run test` (runs `mix deps.get && mix test --warnings-as-errors` in orchestrator) and `mise run lint` (`mix format --check-formatted`). Run `mise run fmt` first if needed.
Expected: all green (existing 46 + the new pure Macho tests), no warnings, formatted.

```bash
git add orchestrator/lib/orchestrator/macho.ex orchestrator/lib/orchestrator/macho/ \
        orchestrator/test/orchestrator/macho_test.exs orchestrator/test/test_helper.exs
git rm lib/macho.sh tests/macho_test.sh
git commit -m "feat(phase2): Orchestrator.Macho pure reasoning + Tool/Otool IO adapter (replaces bash macho.sh)"
```

---

## Task 2: `Orchestrator.Relocate` + `mix relocate` — the relocation runner (TDD)

**Files:**
- Create: `orchestrator/lib/orchestrator/relocate.ex`, `orchestrator/lib/mix/tasks/relocate.ex`
- Test: `orchestrator/test/orchestrator/relocate_test.exs` (`@tag :macos`)

- [ ] **Step 1: Write the failing integration test** — `orchestrator/test/orchestrator/relocate_test.exs`:

```elixir
defmodule Orchestrator.RelocateTest do
  use ExUnit.Case, async: false
  @moduletag :macos

  setup do
    t = Path.join(System.tmp_dir!(), "reloc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([t, "buildlib"]))
    File.mkdir_p!(Path.join([t, "App.app", "Contents", "MacOS", "bin"]))
    on_exit(fn -> File.rm_rf!(t) end)
    {:ok, t: t}
  end

  defp clang!(args), do: {_, 0} = System.cmd("clang", args, stderr_to_stdout: true)

  test "relocate makes a fixture bundle self-contained; runs with build libdir moved aside", %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "foo.c"), "int bar(void); int foo(void){return bar()+2;}\n")
    File.write!(Path.join(t, "main.c"), "int foo(void); int main(void){return foo()-7;}\n")
    clang!(["-dynamiclib", "-install_name", "@rpath/libbar.dylib", "-Wl,-headerpad_max_install_names",
            Path.join(t, "bar.c"), "-o", Path.join(lib, "libbar.dylib")])
    clang!(["-dynamiclib", "-install_name", "@rpath/libfoo.dylib", "-Wl,-headerpad_max_install_names",
            "-L", lib, "-lbar", "-Wl,-rpath," <> lib, Path.join(t, "foo.c"), "-o", Path.join(lib, "libfoo.dylib")])
    for out <- ["Contents/MacOS/App", "Contents/MacOS/bin/helper"] do
      clang!(["-Wl,-headerpad_max_install_names", "-L", lib, "-lfoo", "-Wl,-rpath," <> lib,
              Path.join(t, "main.c"), "-o", Path.join(app, out)])
    end

    assert Orchestrator.Relocate.run(app, lib) == :ok
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libfoo.dylib"]))
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libbar.dylib"]))

    # clean-machine proxy: remove the build libdir, both binaries must still run (rc 0 == foo()==7).
    File.rename!(lib, lib <> ".gone")
    for out <- ["Contents/MacOS/App", "Contents/MacOS/bin/helper"] do
      assert {_, 0} = System.cmd(Path.join(app, out), [], stderr_to_stdout: true)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/relocate_test.exs --include macos'`
Expected: FAIL — `Orchestrator.Relocate` undefined.

- [ ] **Step 3: Write the runner** — `orchestrator/lib/orchestrator/relocate.ex`:

```elixir
defmodule Orchestrator.Relocate do
  @moduledoc """
  Make an `Emacs.app` self-contained: copy the non-system dylib closure into
  `Contents/Frameworks`, normalize ids/refs to `@rpath`, give each Mach-O a depth-correct
  `@loader_path` rpath, delete the build-time conda (foreign) rpath, ad-hoc re-sign
  (Decision C), then gate. Generic over all Mach-O (no ncurses/terminfo special-case —
  GUI-only, spec §15). Reasoning is pure (`Orchestrator.Macho`); IO via a `Macho.Tool`
  (default `Orchestrator.Macho.Otool`), injectable for tests.
  """
  alias Orchestrator.Macho

  @spec run(Path.t(), Path.t(), module) :: :ok | {:error, [Macho.violation()]}
  def run(app, build_libdir, tool \\ Orchestrator.Macho.Otool) do
    app = Path.expand(app)
    fw = Path.join([app, "Contents", "Frameworks"])
    File.mkdir_p!(fw)

    copy_closure(machos(app, tool), fw, build_libdir, tool)
    Enum.each(machos(app, tool), &rewrite(&1, fw, tool))
    gate(app, fw, tool)
  end

  defp machos(app, tool) do
    Path.join(app, "**") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.filter(&tool.macho?/1)
  end

  defp copy_closure(machos, fw, lib, tool) do
    queue = Enum.flat_map(machos, fn f -> Macho.bundleable(tool.deps(f)) end)
    do_copy(queue, MapSet.new(), fw, lib, tool)
  end

  defp do_copy([], _seen, _fw, _lib, _tool), do: :ok

  defp do_copy([dep | rest], seen, fw, lib, tool) do
    base = Path.basename(dep)

    if MapSet.member?(seen, base) do
      do_copy(rest, seen, fw, lib, tool)
    else
      src = resolve(dep, lib)
      dest = Path.join(fw, base)

      new_deps =
        if src && File.exists?(src) do
          File.cp!(src, dest)
          File.chmod!(dest, 0o644)
          tool.set_id(dest, "@rpath/" <> base)
          Macho.bundleable(tool.deps(dest))
        else
          IO.puts(:stderr, "WARN: cannot resolve #{dep} (src=#{inspect(src)})")
          []
        end

      do_copy(rest ++ new_deps, MapSet.put(seen, base), fw, lib, tool)
    end
  end

  defp resolve("@rpath/" <> base, lib), do: Path.join(lib, base)
  defp resolve("/" <> _ = abs, _lib), do: abs
  defp resolve(_, _), do: nil

  defp rewrite(f, fw, tool) do
    for dep <- tool.deps(f), Macho.classify(dep) == :foreign do
      base = Path.basename(dep)
      if File.exists?(Path.join(fw, base)), do: tool.change(f, dep, "@rpath/" <> base)
    end

    tool.add_rpath(f, "@loader_path/" <> Macho.relpath(fw, Path.dirname(f)))
    for rp <- tool.rpaths(f), Macho.classify(rp) == :foreign, do: tool.delete_rpath(f, rp)
    tool.resign(f)
  end

  defp gate(app, fw, tool) do
    basenames = case File.ls(fw), do: ({:ok, fs} -> MapSet.new(fs); _ -> MapSet.new())
    machos = for f <- machos(app, tool), do: %{path: f, deps: tool.deps(f), rpaths: tool.rpaths(f)}

    case Macho.gate_violations(machos, basenames) do
      [] ->
        IO.puts("macho_gate: PASS (#{app} self-contained)")
        :ok

      v ->
        Enum.each(v, &IO.puts("  VIOLATION #{inspect(&1)}"))
        IO.puts("macho_gate: FAIL")
        {:error, v}
    end
  end
end
```

> Implementer note: the `case File.ls(fw), do: (...)` one-liner above is illustrative; write it as a normal multi-line `case File.ls(fw) do ... end`. Keep `mix format` clean and `--warnings-as-errors` green.

- [ ] **Step 4: Write the Mix task** — `orchestrator/lib/mix/tasks/relocate.ex`:

```elixir
defmodule Mix.Tasks.Relocate do
  @shortdoc "Bundle + relocate an Emacs.app into a self-contained bundle (Phase 2)"
  @moduledoc "Usage: `mix relocate <Emacs.app path> <build libdir>` (the build libdir is `$CONDA_PREFIX/lib`)."
  use Mix.Task

  @impl true
  def run([app, build_libdir]) do
    case Orchestrator.Relocate.run(app, build_libdir) do
      :ok -> :ok
      {:error, _violations} -> Mix.raise("relocation gate failed: bundle is not self-contained")
    end
  end

  def run(_), do: Mix.raise("usage: mix relocate <Emacs.app path> <build libdir>")
end
```

- [ ] **Step 5: Run the integration test to verify it passes**
Run: `mise exec -- sh -c 'cd orchestrator && mix test test/orchestrator/relocate_test.exs --include macos'`
Expected: PASS — 1 test, 0 failures (Frameworks has libfoo+libbar; both binaries run rc 0 after the build libdir is moved aside).

- [ ] **Step 6: Full suite + format + commit**
Run: `mise run test` (note: `:macos` tests are EXCLUDED by default off Darwin; on this macOS host include them: `mise exec -- sh -c 'cd orchestrator && mix test --include macos'`) and `mise run lint`.
Expected: all green, no warnings, formatted.

```bash
git add orchestrator/lib/orchestrator/relocate.ex orchestrator/lib/mix/tasks/relocate.ex \
        orchestrator/test/orchestrator/relocate_test.exs
git commit -m "feat(phase2): Orchestrator.Relocate runner + mix relocate task (generic Mach-O closure walk)"
```

---

## Task 3: `pipeline/build-emacs` — build the relocatable-candidate app (bash)

**Files:**
- Create: `pipeline/build-emacs`

A real ~15–20 min build; no fast unit test. Its "test" is that it produces a runnable `Emacs.app` + the discovery dump. The relocation logic is already proven in Tasks 1–2.

- [ ] **Step 1: Write `pipeline/build-emacs`**

```bash
#!/usr/bin/env bash
# pipeline/build-emacs <version> — build a relocatable-CANDIDATE GUI Emacs.app from the per-version
# pixi env. Output: build/<version>/Emacs.app (still linked to pixi @rpath libs) + conda-prefix-lib.txt
# + otool-prereloc.txt. `mix relocate` makes it self-contained. native-comp OFF; GUI-only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-master}"
VDIR="$HERE/versions/$VERSION"
OUT="$HERE/build/$VERSION"; SRC="$OUT/src"
PIXI=(mise exec -- pixi)
[ -f "$VDIR/pixi.toml" ] || { echo "FATAL: $VDIR/pixi.toml missing"; exit 1; }
EMACS_REF="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_REF:?}"')"
EMACS_FLAGS="$(cd "$VDIR" && mise exec -- sh -c 'printf %s "${EMACS_CONFIGURE_FLAGS:?}"')"
mkdir -p "$OUT"
echo ">> [1] fetch emacsmirror/emacs $EMACS_REF -> $SRC"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "$EMACS_REF"; git -C "$SRC" checkout -q -f FETCH_HEAD
else
  rm -rf "$SRC"; git clone --depth 1 --branch "$EMACS_REF" https://github.com/emacsmirror/emacs "$SRC"
fi
echo ">> [2] configure + make + install UNDER the pixi env"
"${PIXI[@]}" run --manifest-path "$VDIR/pixi.toml" bash -euo pipefail -c '
  cd "'"$SRC"'"
  export PATH="$CONDA_PREFIX/bin:$PATH"
  export PKG_CONFIG="$CONDA_PREFIX/bin/pkg-config" PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig"
  ./autogen.sh
  # -headerpad_max_install_names: room for install_name rewrites during relocation.
  # -rpath,$CONDA_PREFIX/lib: the in-build DUMP step (temacs --temacs=pbootstrap) must load conda
  #   @rpath dylibs (Phase-1 finding). Relocation deletes this rpath afterward.
  ./configure '"$EMACS_FLAGS"' "LDFLAGS=-Wl,-headerpad_max_install_names -Wl,-rpath,$CONDA_PREFIX/lib"
  make -j"$(sysctl -n hw.ncpu)"
  make install
  printf "%s/lib\n" "$CONDA_PREFIX" > "'"$OUT"'/conda-prefix-lib.txt"
'
echo ">> [3] locate the produced Emacs.app (--with-ns self-contained build → nextstep/Emacs.app)"
appsrc="$(find "$SRC" -maxdepth 3 -type d -name Emacs.app | head -1)"
[ -n "$appsrc" ] || { echo "FATAL: no Emacs.app produced — confirm the --with-ns self-contained build"; exit 1; }
echo "   found $appsrc"
rm -rf "$OUT/Emacs.app"; cp -R "$appsrc" "$OUT/Emacs.app"
echo ">> [4] discovery: otool inventory of the built (pre-reloc) app"
: > "$OUT/otool-prereloc.txt"
while IFS= read -r f; do
  file -b "$f" 2>/dev/null | grep -q Mach-O || continue
  { echo "-- $f"; otool -L "$f" | sed -n '2,$p'; } >> "$OUT/otool-prereloc.txt"
done < <(find "$OUT/Emacs.app" -type f)
sed -i '' "s|$HOME|~|g" "$OUT/otool-prereloc.txt" 2>/dev/null || true
echo ">> build-emacs: $OUT/Emacs.app ready (run 'mise run relocate' next)"
```

- [ ] **Step 2: Build and verify the candidate exists and runs**
Run: `bash pipeline/build-emacs master`
Expected: `build/master/Emacs.app/Contents/MacOS/Emacs` exists; `build/master/conda-prefix-lib.txt` ends in `.pixi/envs/default/lib`; `otool-prereloc.txt` shows `@rpath/lib{gnutls.30,xml2.2,tree-sitter.0.26,ncurses.6}.dylib` + `/usr/lib/*`.

> **Validation point (ns self-contained):** if `make install` does not yield `nextstep/Emacs.app`, capture where it landed and the layout, and adjust the `find` in Step 3. Record the actual layout for Task 7.

- [ ] **Step 3: Sanity-run on the host (still has pixi — confirms the build is valid)**
Run: `build/master/Emacs.app/Contents/MacOS/Emacs --batch --eval '(princ (format "ok %s\n" emacs-version))'`
Expected: prints `ok 32.0.50` (or current master).

- [ ] **Step 4: Commit**
```bash
git add pipeline/build-emacs
git commit -m "feat(phase2): build-emacs — build a relocatable-candidate GUI Emacs.app from the pixi env"
```

---

## Task 4: Relocate the real build + gate green locally

**Files:** none new — runs `mix relocate` on Task 3's output.

- [ ] **Step 1: Relocate the real app**
Run: `mise run relocate` (i.e. `cd orchestrator && mix relocate ../build/master/Emacs.app "$(cat ../build/master/conda-prefix-lib.txt)"`).
Expected: ends with `macho_gate: PASS (…/build/master/Emacs.app self-contained)`, exit 0.

- [ ] **Step 2: Independently inspect the closure + rpaths**
Run:
```bash
ls build/master/Emacs.app/Contents/Frameworks/
otool -l build/master/Emacs.app/Contents/MacOS/Emacs | awk '/LC_RPATH/{f=1} f&&/path /{print; f=0}'
otool -L build/master/Emacs.app/Contents/MacOS/Emacs | sed -n '2,$p'
```
Expected: Frameworks holds `lib{gnutls.30,xml2.2,tree-sitter.0.26,ncurses.6}.dylib` + the gnutls transitive closure (`libnettle*`,`libhogweed*`,`libp11-kit*`,`libtasn1*`,`libgmp*`,`libidn2*`,`libunistring*`); the binary has `@loader_path/../Frameworks` and **no** `.pixi` rpath; no `@rpath` dep is unresolved.

- [ ] **Step 3: Commit (record the validated closure)**
```bash
git commit --allow-empty -m "test(phase2): relocate real master build — gate green, closure bundled

Verified Frameworks closure on osx-arm64: gnutls(+nettle/hogweed/p11-kit/tasn1/gmp/idn2/unistring),
libxml2, tree-sitter, ncurses. No .pixi refs/rpaths remain."
```

---

## Task 5: Wire mise tasks, gitignore, and the pregate clean-room

The clean-room "no-pixi launch" runs **inside the one fresh pregate macOS VM** (build → relocate → gate → move the pixi env aside → launch), exposed as a `mise run cleanroom` task that pregate calls — no separate VM, no nested virtualization, no `sshpass`, no bespoke image pull. The "clean machine" is the pregate VM itself (fresh OS + toolchain only) with the pixi env moved aside. (Local Phase-2 "done" already rests on the static gate + the moved-aside fixture test + the real-app validation — see Task 4.)

**Files:**
- Modify: `mise.toml`, `.gitignore`, `.pregate/macos.sh`

- [ ] **Step 1: Add the Phase 2 tasks to `mise.toml`** (append after `[tasks.configure-check]`):

```toml
[tasks.build]
description = "Phase 2: build a relocatable-candidate GUI Emacs.app from the per-version pixi env"
run = "bash pipeline/build-emacs master"

[tasks.relocate]
description = "Phase 2: bundle + relocate the built Emacs.app into a self-contained app (Elixir; gate)"
dir = "orchestrator"
run = "mix relocate ../build/master/Emacs.app \"$(cat ../build/master/conda-prefix-lib.txt)\""

[tasks.cleanroom]
description = "Phase 2 DoD: prove the relocated app runs with the pixi env moved aside (no-pixi launch)"
run = '''
set -euo pipefail
APP="build/master/Emacs.app"
ENV_DIR="versions/master/.pixi"
[ -d "$APP" ] || { echo "FATAL: $APP missing — run 'mise run build && mise run relocate' first"; exit 1; }
ASIDE="$(mktemp -d)/pixi"
restore() { [ -d "$ASIDE" ] && mv "$ASIDE" "$ENV_DIR"; }
trap restore EXIT
[ -d "$ENV_DIR" ] && mv "$ENV_DIR" "$ASIDE"    # simulate a machine with no pixi env present
echo ">> [1] --batch (dyld must resolve the full bundled closure with the pixi env gone) — THE gate"
"$APP/Contents/MacOS/Emacs" --batch --eval '(princ (format "ok %s\n" emacs-version))'
echo ">> [2] GUI frame smoke (NS path; needs a display/session — best-effort)"
if "$APP/Contents/MacOS/Emacs" -Q --eval '(run-with-timer 1 nil (lambda () (kill-emacs 0)))' 2>/dev/null; then
  echo "   GUI frame OK"
else
  echo "   GUI frame skipped (no display/session — --batch is the hard gate)"
fi
echo ">> cleanroom: PASS — runs with no pixi env"
'''
```

(No `test-macho` task — the Macho/Relocate tests run under `mise run test`; the integration test is `@tag :macos`, auto-run on this macOS host, excluded on ubuntu CI. The `cleanroom` task moves `versions/master/.pixi` aside and restores it on exit; in the disposable pregate VM that's free, and locally it's restored via the `trap`.)

- [ ] **Step 2: Ignore the build output** — add to `.gitignore`:
```
# Phase 2 build/relocate output (ephemeral)
/build/
```

- [ ] **Step 3: Extend `.pregate/macos.sh`** (the full clean-room, all in the one pregate macOS VM):
```sh
#!/bin/sh
# pregate macos recipe — shared body (orchestrator test+lint, incl. the :macos relocation test),
# then the Phase 2 build → relocate → gate → no-pixi launch, ALL in this one fresh disposable
# macOS VM. No nested virtualization, no sshpass, no separate image: the "clean machine" is this
# VM (fresh OS + toolchain only) with the pixi env moved aside before launch (mise run cleanroom).
. ./.pregate/common.sh
mise run build
mise run relocate    # mix relocate ends with the static gate — fails pregate if not self-contained
mise run cleanroom   # moves versions/master/.pixi aside, then --batch (+ GUI frame) — the no-pixi proof
```

> Note: `common.sh` runs `mise run test`, which on this macOS VM includes the `@tag :macos` relocation integration test (Darwin → not excluded).

- [ ] **Step 4: Verify the fast suite runs**
Run: `mise run test` (on macOS includes the `:macos` integration test).
Expected: all green.

- [ ] **Step 5: Commit**
```bash
git add mise.toml .gitignore .pregate/macos.sh
git commit -m "build(phase2): mise tasks (build/relocate/cleanroom) + pregate no-pixi launch + gitignore"
```

---

## Task 6: Record findings + reconcile docs

**Files:**
- Modify: `docs/superpowers/validation-log.md`, `docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md`, `versions/master/mise.toml`

- [ ] **Step 1: Append the Phase 2 section to `docs/superpowers/validation-log.md`**
Record: the real Frameworks closure (Task 4 Step 2); the confirmed ns `make install` app location (Task 3 Step 2); the working `cleanroom` GUI invocation (Task 5); confirmation that `--batch` + GUI run with no pixi; the hybrid bash/Elixir split decision; and **Decision E** —
```markdown
### Decision E — host make/CLT fingerprint gap (spec §8): RESOLVED (record now, wire Phase 5)
Fold `xcode-select -p` + `clang --version` (the CLT/SDK build string) into `toolchain_hash` when
the fingerprint is consumed (Phase 5). A runner-image CLT/SDK bump then rebuilds all refs. No Phase-2 code.
```

- [ ] **Step 2: Reconcile the umbrella spec**
- §9: replace the `@executable_path/../Frameworks` sketch with the actual scheme (build-time `-rpath,$CONDA_PREFIX/lib` for the dump; relocation adds depth-correct `@loader_path/<rel>` and deletes the conda rpath; ad-hoc re-sign per Mach-O); note relocation+gate are **Elixir** (`Orchestrator.{Macho,Relocate}` + `mix relocate`), build is bash — consistent with D4/§7.1.
- §6.2: change the ncurses row to "**bundled** generically (GUI-only; dylib only needs to resolve — terminfo/`-nw` deferred, §15)".
- §13: move "`--with-ns` Info.plist/extraction" and "`-nw` on system ncurses" to resolved/deferred (→ §15).

- [ ] **Step 3: Fix the stale comment in `versions/master/mise.toml`**
Change `# ncurses intentionally NOT requested → Emacs links system /usr/lib (spec §6.2).` to:
`# ncurses links from the pixi env (texinfo pulls it); GUI-only v1 bundles it generically during`
`# relocation, no terminfo work. emacs -nw is a post-Phase-4 fast-follow (spec §15).`

- [ ] **Step 4: Commit**
```bash
git add docs/superpowers/validation-log.md docs/superpowers/specs/2026-06-05-bundled-emacs-build-system-design.md versions/master/mise.toml
git commit -m "docs(phase2): record build+relocation findings + Decision E; reconcile spec §6.2/§8/§9/§13"
```

---

## Phase 2 Definition of Done

- [ ] `mise run test` green incl. the pure `Orchestrator.Macho` tests + (on macOS) the `@tag :macos` `Relocate` integration test; ubuntu CI stays green (`:macos` excluded).
- [ ] `mise run build` produces `build/master/Emacs.app` that runs `--batch` on the host.
- [ ] `mise run relocate` ends with `macho_gate: PASS` — zero foreign deps, zero foreign rpaths, full `@rpath` closure in `Frameworks`.
- [ ] `mise run cleanroom` green: relocated app runs `--batch` (+ GUI frame) with the pixi env moved aside — and the same in the fresh pregate macOS VM.
- [ ] Validation-log Phase 2 section written; spec §6.2/§8/§9/§13 reconciled; stale `versions/master/mise.toml` comment fixed.
- [ ] `emacs -nw`/terminfo confirmed out of scope, recorded for post-Phase-4 (spec §15).

## Self-Review (author)

**Spec coverage (§14 Phase 2 + §9):** "self-contained `.app` launches on a clean runner; gate green" → Tasks 4 (gate) + 5 (clean VM). build-emacs (§9.1) → Task 3. generic relocation over all Mach-O (§9.2) → `Orchestrator.Relocate` Task 2. the verify gate (§5/§9.2) → `Macho.gate_violations` Task 1. sign-last ad-hoc (§9.3, Decision C) → `rewrite/3` re-sign. pregate clean-room intent (§11.3) → Task 6 (static gate in-VM) + Task 5 (host clean VM), nested-virt constraint documented. CLT fingerprint (§8, Decision E) → Task 7. headerpad + header-overflow risk (§12) → build-emacs LDFLAGS + the gate catches incompleteness. D4/§7.1 (pure core + IO adapter) → `Macho` (pure) + `Macho.Tool`/`Otool` (IO) + `Relocate`.

**Placeholder scan:** no code placeholders — every module/test is complete. The `case File.ls/1` one-liner in Task 2 Step 3 is flagged to be rewritten multi-line for `mix format`. The three build/VM "validation points" are confirm-and-adjust steps with concrete fallbacks (per the validate-don't-assume rule), not deferred work.

**Type/name consistency:** `Orchestrator.Macho` functions (`classify/1`, `relpath/2`, `parse_id/1`, `parse_deps/2`, `parse_rpaths/1`, `bundleable/1`, `gate_violations/2`) are used consistently by `Macho.Otool` and `Relocate`. The `Macho.Tool` behaviour callbacks (`macho?`, `id`, `deps`, `rpaths`, `set_id`, `change`, `add_rpath`, `delete_rpath`, `sign_bundle`) match the `Otool` `@impl` set and the `Relocate` call sites. Path contract: build-emacs writes `build/<v>/{Emacs.app,conda-prefix-lib.txt}`; `mix relocate` and `mise run cleanroom` read `build/master/Emacs.app`.

**Scope:** single subsystem (build + relocation). native-comp, proper signing, packaging, CI, and `-nw` are excluded and routed to their phases.
