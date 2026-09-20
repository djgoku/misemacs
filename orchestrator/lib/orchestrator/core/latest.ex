defmodule Orchestrator.Core.Latest do
  @moduledoc """
  Pure 'latest' selection. No IO.

  Select by numeric SemVer components for new Packslip tags. Legacy tags retain
  lexical ordering for old manifest fixtures. finalize runs per channel repo.
  """
  @spec latest_target([String.t()]) :: {:set, String.t()} | :unchanged
  def latest_target([]), do: :unchanged
  def latest_target(tags) when is_list(tags), do: {:set, Enum.max_by(tags, &sort_key/1)}

  @doc "Sort Packslip tags by numeric version, with legacy tags before them."
  @spec sort_tags([String.t()]) :: [String.t()]
  def sort_tags(tags), do: Enum.sort_by(tags, &sort_key/1)

  defp sort_key(tag) do
    case Regex.run(~r/^v(\d+)\.(\d+)\.(\d+)$/, tag, capture: :all_but_first) do
      [year, month, patch] ->
        {1, String.to_integer(year), String.to_integer(month), String.to_integer(patch)}

      _ ->
        {0, tag}
    end
  end
end
