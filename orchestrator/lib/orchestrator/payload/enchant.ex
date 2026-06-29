defmodule Orchestrator.Payload.Enchant do
  @moduledoc """
  The bundled-enchant companion payload. enchant is staged as a self-contained sub-prefix at
  `Emacs.app/Contents/Resources/enchant/` and relocated with **bundle-root = `enchant/lib`**
  (NOT `Contents/Frameworks`), because the feedstock's `dladdr` self-relocation requires
  `<prefix>/lib/libenchant-2.2.dylib` + `<prefix>/lib/enchant-2/` (design §5.1/§7).

  Pure here: the exact bytes of the four generated files. The copy/relocate/sign IO is the
  `stage_copy/3` → `relocate/2` → `verify/3` runner (reuses `Orchestrator.Macho`, IO via
  `Orchestrator.Macho.Tool`).
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
    echo "$out"
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
                          (dolist (dir load-path)
                            (dolist (mod (file-expand-wildcards (expand-file-name "jinx-mod*.so" dir)))
                              (ignore-errors (misemacs--enchant-rpath-fix mod lib))))
                          (let ((exec-path (cons bin exec-path))) (apply orig args))))))))
    """
  end

  @doc "enchant.ordering making applespell the default backend (design §13, spike-C)."
  @spec ordering_contents() :: String.t()
  def ordering_contents, do: "*:applespell,hunspell\n"

  # --- IO runner (Task 3): stage_copy → relocate → verify, bundle-root = enchant/lib ---

  @spec ench_dir(Path.t()) :: Path.t()
  defp ench_dir(app), do: Path.join(Path.expand(app), @enchant_rel)

  @doc "Copy enchant + its closure out of `conda_prefix` into the app sub-prefix (no relocation yet)."
  @spec stage_copy(Path.t(), Path.t(), module) :: :ok
  def stage_copy(app, conda_prefix, tool \\ Orchestrator.Macho.Otool) do
    ench = ench_dir(app)
    lib = Path.join(ench, "lib")
    File.mkdir_p!(Path.join(lib, "enchant-2"))
    File.mkdir_p!(Path.join(ench, "include/enchant-2"))
    File.mkdir_p!(Path.join(ench, "lib/pkgconfig"))
    File.mkdir_p!(Path.join(ench, "share/enchant-2"))
    File.mkdir_p!(Path.join(ench, "bin"))
    File.mkdir_p!(Path.join(app, "Contents/Resources/site-lisp"))
    src = fn rel -> Path.join(conda_prefix, rel) end

    # 1. libenchant + the providers are the relocation ROOTS; copy them in...
    cp!(src.("lib/libenchant-2.2.dylib"), Path.join(lib, "libenchant-2.2.dylib"))
    # spike-A: -lenchant-2 target. Idempotent: drop any prior link before recreating.
    _ = File.rm(Path.join(lib, "libenchant-2.dylib"))
    File.ln_s!("libenchant-2.2.dylib", Path.join(lib, "libenchant-2.dylib"))

    for so <- Path.wildcard(Path.join(src.("lib/enchant-2"), "enchant_*.so")) do
      cp!(so, Path.join([lib, "enchant-2", Path.basename(so)]))
    end

    # 2. ...then BFS their foreign closure into enchant/lib (Macho primitives, bundle-root = lib).
    roots = [
      Path.join(lib, "libenchant-2.2.dylib") | Path.wildcard(Path.join(lib, "enchant-2/*.so"))
    ]

    copy_closure(roots, lib, Path.join(conda_prefix, "lib"), tool)

    # 3. SDK + CLIs + generated files. (R3: CLIs must be executable — cp_exec!, not cp!.)
    for h <- Path.wildcard(Path.join(src.("include/enchant-2"), "*.h")) do
      cp!(h, Path.join([ench, "include/enchant-2", Path.basename(h)]))
    end

    for b <- ["enchant-2", "enchant-lsmod-2"], File.exists?(src.("bin/#{b}")) do
      cp_exec!(src.("bin/#{b}"), Path.join([ench, "bin", b]))
    end

    File.write!(Path.join(ench, "lib/pkgconfig/enchant-2.pc"), pc_contents())
    write_exec!(Path.join(ench, "bin/pkg-config"), pkgconfig_shim())
    File.write!(Path.join(ench, "share/enchant-2/enchant.ordering"), ordering_contents())
    File.write!(Path.join(app, "Contents/Resources/site-lisp/site-start.el"), site_start_el())

    # 4. AppleSpell.config — the applespell locale map (e.g. "en_US\ten\tEnglish") shipped by the
    #    feedstock at share/enchant-2/. REQUIRED for applespell (the default backend): without it
    #    applespell claims no locale, `enchant_broker_dict_exists("en_US")` returns 0, and enchant
    #    falls back to the bare-language tag, which hits a flaky upstream applespell NULL-deref
    #    crash (verified 2026-06-28). Copy it verbatim from the prefix when present.
    apple_config = src.("share/enchant-2/AppleSpell.config")

    if File.exists?(apple_config) do
      cp!(apple_config, Path.join(ench, "share/enchant-2/AppleSpell.config"))
    end

    # 5. Bundled en_US hunspell dictionary — the "working hunspell option" (applespell is the
    #    default; hunspell is selectable per design §13). Vendored in-repo under priv/ with a
    #    permissive SCOWL/LibreOffice license (README ships beside the data). Staged at the XDG
    #    data location <prefix>/share/hunspell so the hunspell provider finds it when the bundle's
    #    share is on XDG_DATA_DIRS (the provider searches g_get_system_data_dirs()/hunspell +
    #    ~/.config/enchant/hunspell — NOT the enchant prefix, so dladdr relocation doesn't reach it).
    hunspell_dst = Path.join(ench, "share/hunspell")
    File.mkdir_p!(hunspell_dst)

    for f <- Path.wildcard(Path.join(hunspell_dict_dir(), "*")) do
      cp!(f, Path.join(hunspell_dst, Path.basename(f)))
    end

    :ok
  end

  @doc "Normalize ids/deps/rpaths within the staged sub-prefix to @rpath/@loader_path, then per-file sign."
  @spec relocate(Path.t(), module) :: :ok
  def relocate(app, tool \\ Orchestrator.Macho.Otool) do
    ench = ench_dir(app)
    lib = Path.join(ench, "lib")

    for m <- machos(ench, tool) do
      # R2: providers are MH_BUNDLE and the CLIs are executables — neither carries an id.
      # `install_name_tool -id` (asserted exit 0 by Otool.set_id) errors on a non-dylib; guard it.
      if tool.id(m), do: tool.set_id(m, "@rpath/" <> Path.basename(m))

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

  @doc """
  Gate: otool self-containment over `enchant/**` + per-file `codesign --verify --strict`.

  `conda_prefix` is accepted for signature stability with the pipeline but is unused: the former
  build-prefix `leak_check` (a `strings`-grep for the prefix) was **dropped** (2026-06-28). Real
  conda dylibs bake the install prefix into inert data-section strings that `install_name_tool`
  cannot strip, so the check false-flagged 6 legitimately-relocated libs. The self-containment
  that matters is in the load commands (proven by the macho gate) and is confirmed functionally
  by the cleanroom run; `dladdr` self-relocation overrides any compiled-in prefix at runtime.
  """
  @spec verify(Path.t(), Path.t(), module) :: :ok | {:error, term}
  def verify(app, _conda_prefix, tool \\ Orchestrator.Macho.Otool) do
    ench = ench_dir(app)
    lib = Path.join(ench, "lib")
    basenames = lib |> File.ls!() |> MapSet.new()

    machos =
      for m <- machos(ench, tool), do: %{path: m, deps: tool.deps(m), rpaths: tool.rpaths(m)}

    with [] <- Macho.gate_violations(machos, basenames),
         :ok <- verify_sigs(machos, tool) do
      IO.puts("enchant_gate: PASS (#{ench} self-contained)")
      :ok
    else
      {:error, _} = e ->
        e

      violations ->
        Enum.each(violations, &IO.puts("  VIOLATION #{inspect(&1)}"))
        IO.puts("enchant_gate: FAIL")
        {:error, violations}
    end
  end

  # --- helpers (mirror Orchestrator.Relocate's closure walk, bundle-root = enchant/lib) ---

  # R4: skip symlinks. `File.regular?/1` follows links — it would re-resolve the unversioned
  # `libenchant-2.dylib` link to the versioned dylib and double-edit it. `File.lstat/1` does not.
  defp machos(ench, tool) do
    Path.join(ench, "**")
    |> Path.wildcard()
    |> Enum.filter(fn p ->
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(p))
    end)
    |> Enum.filter(&tool.macho?/1)
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

      new =
        if (from && File.exists?(from)) and not File.exists?(dest) do
          cp!(from, dest)
          Macho.bundleable(tool.deps(dest))
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

  # The vendored en_US hunspell dictionary (priv/enchant/hunspell/en_US/{en_US.aff,en_US.dic,
  # README_en_US.txt}). Permissive SCOWL/LibreOffice license — see the bundled README.
  defp hunspell_dict_dir, do: Path.join(:code.priv_dir(:orchestrator), "enchant/hunspell/en_US")

  defp cp!(from, to) do
    File.cp!(from, to)
    File.chmod!(to, 0o644)
  end

  # R3: enchant-2 / enchant-lsmod-2 are executables; pipeline/package's `-x` check needs 0755.
  defp cp_exec!(from, to) do
    File.cp!(from, to)
    File.chmod!(to, 0o755)
  end

  defp write_exec!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
