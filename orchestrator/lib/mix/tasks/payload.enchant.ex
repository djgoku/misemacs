defmodule Mix.Tasks.Payload.Enchant do
  @shortdoc "Stage (copy) the bundled enchant payload into an Emacs.app"
  @moduledoc """
  Usage: `mix payload.enchant <Emacs.app path> <conda_prefix>` (conda_prefix = `$CONDA_PREFIX`).

  Copy-only: stages enchant + its dylib closure + the generated files into
  `Emacs.app/Contents/Resources/enchant/`. Relocation, per-file signing, and the
  self-containment gate run later as part of `mix relocate` (Task 4).
  """
  use Mix.Task
  alias Orchestrator.Payload.Enchant

  @impl true
  def run([app, conda_prefix]) do
    :ok = Enchant.stage_copy(app, conda_prefix)
  end

  def run(_), do: Mix.raise("usage: mix payload.enchant <Emacs.app path> <conda_prefix>")
end
