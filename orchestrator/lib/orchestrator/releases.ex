defmodule Orchestrator.Releases do
  @moduledoc """
  IO behaviour: read the cross-run state — the `build-manifest.json` attached to a recent
  git tag in the per-channel release repo (newest-first bounded scan: a just-published
  release may not have its manifest attached until finalize runs). Three-way result:

    * `{:ok, manifest}`   — a recent tag carries a valid manifest
    * `:empty`            — repo reachable but no manifest found (first run / in-flight only)
    * `{:error, reason}`  — the tag list fetch failed (repo unreachable / auth failure)

  Callers must handle all three cases; `:empty` means no prior state (callers rebuild).
  """
  @callback last_manifest(repo :: String.t()) :: {:ok, map()} | :empty | {:error, term()}
end
