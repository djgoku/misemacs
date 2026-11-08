defmodule Mix.Tasks.Payload.Enchant do
  @shortdoc "Stage (copy) the bundled enchant payload into build/<version>/Emacs.app"
  @moduledoc """
  Usage: `mix payload.enchant [version] [--root ..]` (version defaults to master).

  Copy-only: stages enchant + its dylib closure + the generated files into
  `Emacs.app/Contents/Resources/enchant/`. Run after `mise run build` and before
  `mise run relocate`, which relocates, signs, and gates the payload.
  """
  use Mix.Task
  alias Orchestrator.BuildDir
  alias Orchestrator.Payload.Enchant

  @impl true
  def run(argv) do
    {root, version} = Mix.Tasks.Relocate.parse(argv)

    case BuildDir.load(root, version) do
      {:ok, build} -> :ok = Enchant.stage_copy(build.app, BuildDir.conda_prefix(build))
      {:error, msg} -> Mix.raise(msg)
    end
  end
end
