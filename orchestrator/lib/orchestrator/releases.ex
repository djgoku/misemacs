defmodule Orchestrator.Releases do
  @moduledoc """
  IO behaviour: read the cross-run state — the `build-manifest.json` attached to the
  lexical-newest git tag in the per-channel release repo. Three-way result:

    * `{:ok, manifest}`   — newest tag carries a valid manifest
    * `:empty`            — repo reachable but has no tags (genuine first run)
    * `{:error, reason}`  — repo unreachable / auth failure / newest tag has no/corrupt manifest

  Callers must handle all three cases; `:empty` is the pristine-repo / first-run signal.
  """
  @callback last_manifest(repo :: String.t()) :: {:ok, map()} | :empty | {:error, term()}
end
