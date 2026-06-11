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
      Regex.match?(~r/^\s*cmd LC_RPATH\s*$/, line) ->
        rpaths(rest, acc, true)

      in? and Regex.match?(~r/^\s*path /, line) ->
        p =
          line
          |> String.replace(~r/^\s*path /, "")
          |> String.replace(~r/ \(offset \d+\)\s*$/, "")

        rpaths(rest, [p | acc], false)

      true ->
        rpaths(rest, acc, in?)
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
