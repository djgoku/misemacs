defmodule Orchestrator.Core.Latest do
  @moduledoc """
  Pure 'latest' selection. No IO.

  The newest tag is the lexical MAX of the built tags — zero-padded ISO dates sort
  chronologically and `.N` same-day collision suffixes sort newest, the same ordering
  aqua's `github_tag` resolution relies on. finalize is invoked per artifact repo
  (per channel), so the input is one channel's tags. `:unchanged` when nothing was built.
  """
  @spec latest_target([String.t()]) :: {:set, String.t()} | :unchanged
  def latest_target([]), do: :unchanged
  def latest_target(tags) when is_list(tags), do: {:set, Enum.max(tags)}
end
