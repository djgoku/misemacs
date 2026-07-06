defmodule Orchestrator.Upstream do
  @moduledoc """
  IO behaviour: resolve a git ref in the version's upstream repo (`Naming.upstream/1` —
  per-version `versions.toml upstream` override, else the shared default) to its commit
  sha. The adapter MUST normalize an absent/unresolvable ref to `nil` (never raise) —
  `Core.Detect` maps `nil` → `{false, :no_upstream}` (a skip, never a rebuild).
  """
  @callback resolve(url :: String.t(), ref :: String.t()) :: String.t() | nil
end
