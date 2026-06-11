defmodule Mix.Tasks.Relocate do
  @shortdoc "Bundle + relocate an Emacs.app into a self-contained bundle (Phase 2)"
  @moduledoc "Usage: `mix relocate <Emacs.app path> <build libdir>` (the build libdir is `$CONDA_PREFIX/lib`)."
  use Mix.Task

  @impl true
  def run([app, build_libdir]) do
    case Orchestrator.Relocate.run(app, build_libdir) do
      :ok ->
        :ok

      {:error, {:signature_invalid, reason}} ->
        Mix.raise("bundle signature verification failed: #{reason}")

      {:error, _violations} ->
        Mix.raise("relocation gate failed: bundle is not self-contained")
    end
  end

  def run(_), do: Mix.raise("usage: mix relocate <Emacs.app path> <build libdir>")
end
