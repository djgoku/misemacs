defmodule Misemacs.Lib do
  @moduledoc """
  Shared pure logic + thin shell wrappers for the misemacs `.exs` CLI scripts.

  Pure functions (parse_calver/compare_calver/latest_tag/next_calver/decide/
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

  @doc "Total order on parsed calver tuples (numeric per field, not lexical)."
  def compare_calver(a, b) when a < b, do: :lt
  def compare_calver(a, b) when a > b, do: :gt
  def compare_calver(_, _), do: :eq

  @doc """
  Given a list of full tag names and a flavor, return the highest
  `<flavor>-<calver>` tag by numeric calver order, or nil. Prefix match is
  exact on `<flavor>-`, so `emacs-master` never matches `emacs-mac-master-*`.
  """
  def latest_tag(tags, flavor) do
    prefix = flavor <> "-"

    parsed =
      tags
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
end
