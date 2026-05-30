defmodule Misemacs.Lib do
  @moduledoc """
  Shared pure logic + thin shell wrappers for the misemacs `.exs` CLI scripts.

  Pure functions (parse_calver/latest_tag/next_calver/decide/
  parse_ls_remote/inputs_hash) are unit-tested in scripts/test/*_test.exs.
  sh/2 and die/1 do IO/exit and are exercised only by the scripts themselves.
  """

  # ---- calendar version ----

  @calver_re ~r/^(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$/

  @doc "Parse a calver string into a comparable {y, m, d, n} tuple, or nil."
  def parse_calver(str) when is_binary(str) do
    case Regex.run(@calver_re, str) do
      [_, y, m, d] -> {int(y), int(m), int(d), 0}
      [_, y, m, d, n] -> {int(y), int(m), int(d), int(n)}
      nil -> nil
    end
  end

  def parse_calver(_), do: nil

  def valid_calver?(str), do: parse_calver(str) != nil

  @doc """
  Given a list of full tag names and a flavor, return the highest
  `<flavor>-<calver>` tag by numeric calver order, or nil. Prefix match is
  exact on `<flavor>-`, so `emacs-master` never matches `emacs-mac-master-*`.
  """
  def latest_tag(tags, flavor) do
    prefix = flavor <> "-"

    parsed =
      tags
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(fn tag -> {tag, parse_calver(String.replace_prefix(tag, prefix, ""))} end)
      |> Enum.reject(fn {_tag, ver} -> ver == nil end)

    case parsed do
      [] -> nil
      list -> list |> Enum.max_by(fn {_tag, ver} -> ver end) |> elem(0)
    end
  end

  @doc """
  First free calver for `today` given a MapSet of already-taken calver strings
  (suffix-less, e.g. "2026.05.30" and "2026.05.30.1").
  """
  def next_calver(today, existing) do
    if MapSet.member?(existing, today), do: next_suffixed(today, existing, 1), else: today
  end

  defp next_suffixed(today, existing, n) do
    candidate = "#{today}.#{n}"
    if MapSet.member?(existing, candidate), do: next_suffixed(today, existing, n + 1), else: candidate
  end

  defp int(s), do: String.to_integer(s)

  # ---- input fingerprint ----

  @doc "Lowercase hex sha256 of a binary."
  def sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  @doc """
  Stable sha256 over a flavor's build inputs, computed relative to `root`.

  Scheme (documented for reproducibility): for each input file compute
  sha256(bytes) as lowercase hex; build lines "<hex>  <relative-path>";
  sort lines BY PATH; join with "\\n" and a trailing "\\n"; sha256 that blob.
  Raises if the flavor is unknown or any expected input file is missing.
  """
  def inputs_hash(root, flavor) do
    unless File.exists?(Path.join(root, "pkgs/#{flavor}/lockfile.toml")) do
      raise "inputs-hash: unknown flavor '#{flavor}'"
    end

    rel_paths =
      [
        "pkgs/#{flavor}/lockfile.toml",
        "pkgs/#{flavor}/build.toml",
        "mise.lock"
      ] ++
        wildcard_rel(root, "libs/*/lockfile.toml") ++
        wildcard_rel(root, "libs/*/build.toml") ++
        wildcard_rel(root, "scripts/build/*.sh")

    lines =
      rel_paths
      |> Enum.sort()
      |> Enum.map(fn rel ->
        hex = root |> Path.join(rel) |> File.read!() |> sha256_hex()
        "#{hex}  #{rel}"
      end)

    sha256_hex(Enum.join(lines, "\n") <> "\n")
  end

  defp wildcard_rel(root, glob) do
    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  # ---- release-skip decision ----

  @doc """
  Decide whether a flavor needs a build+release. `opts` is
  %{force: bool, version_given: bool}. Rebuild if forced, if an explicit
  version was requested, if there is no prior recorded hash, or if the current
  hash differs from the previous one.
  """
  def decide(_cur, _prev, %{force: true}), do: true
  def decide(_cur, _prev, %{version_given: true}), do: true
  def decide(_cur, nil, _opts), do: true
  def decide(_cur, "", _opts), do: true
  def decide(cur, prev, _opts), do: cur != prev

  # ---- ls-remote ref resolution ----

  @doc """
  Given `git ls-remote` output (lines of "<sha>\\t<ref>"), return:
  {:ok, sha} for exactly one distinct sha, {:error, :none} for no matches,
  {:error, :ambiguous} when matching refs resolve to different shas.
  """
  def parse_ls_remote(output) do
    shas =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split(["\t", " "], trim: true) |> List.first() end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case shas do
      [] -> {:error, :none}
      [sha] -> {:ok, sha}
      _ -> {:error, :ambiguous}
    end
  end

  # ---- process helpers (used by scripts, not unit-tested) ----

  @doc "Run a command, return trimmed stdout, raise on nonzero exit."
  def sh(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out)
      {out, code} -> raise "#{cmd} #{Enum.join(args, " ")} failed (exit #{code}):\n#{out}"
    end
  end

  @doc "Print a message to stderr and halt with exit code 1."
  def die(msg) do
    IO.puts(:stderr, msg)
    System.halt(1)
  end
end
