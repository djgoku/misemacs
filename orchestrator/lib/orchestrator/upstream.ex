defmodule Orchestrator.Upstream do
  @moduledoc """
  IO behaviour: resolve a git ref in `emacsmirror/emacs` to its commit sha. The adapter
  MUST normalize an absent/unresolvable ref to `nil` (never raise) — `Core.Detect` maps
  `nil` → `{false, :no_upstream}` (a skip, never a rebuild).
  """
  @callback resolve(ref :: String.t()) :: String.t() | nil
end
