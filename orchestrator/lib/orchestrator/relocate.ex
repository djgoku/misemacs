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
    Path.join(app, "**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&tool.macho?/1)
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

  # Single-libdir assumption: every `@rpath/*` dep is resolved under `build_libdir`
  # (`$CONDA_PREFIX/lib`). Anything not found there warns (`do_copy`) and is caught by
  # the gate as `:missing_lib` rather than silently dropped.
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
    basenames =
      case File.ls(fw) do
        {:ok, fs} -> MapSet.new(fs)
        _ -> MapSet.new()
      end

    machos =
      for f <- machos(app, tool), do: %{path: f, deps: tool.deps(f), rpaths: tool.rpaths(f)}

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
