defmodule Orchestrator.Core.Latest do
  @moduledoc """
  Pure 'latest' selection. No IO.

  v1 policy: the newest build of the run becomes `latest`. The caller (Phase 5
  `finalize`) MUST pass `built_tags` in release-recency order (oldest → newest); the last
  element is chosen. `:unchanged` when nothing was built. (Per-channel `latest` is a
  future enhancement; spec §11.1.)
  """
  @spec latest_target([String.t()]) :: {:set, String.t()} | :unchanged
  def latest_target([]), do: :unchanged
  def latest_target(built_tags) when is_list(built_tags), do: {:set, List.last(built_tags)}
end
