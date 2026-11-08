defmodule Mix.Tasks.Relocate do
  @shortdoc "Bundle + relocate build/<version>/Emacs.app into a self-contained bundle (Phase 2)"
  @moduledoc "Usage: `mix relocate [version] [--root ..]` (version defaults to master)."
  use Mix.Task
  alias Orchestrator.BuildDir

  @impl true
  def run(argv) do
    {root, version} = parse(argv)

    build =
      case BuildDir.load(root, version) do
        {:ok, build} -> build
        {:error, msg} -> Mix.raise(msg)
      end

    case Orchestrator.Relocate.run(build.app, build.conda_lib) do
      :ok ->
        :ok

      {:error, {:signature_invalid, reason}} ->
        Mix.raise("bundle signature verification failed: #{reason}")

      {:error, _violations} ->
        Mix.raise("relocation gate failed: bundle is not self-contained")
    end
  end

  @doc false
  def parse(argv) do
    case OptionParser.parse(argv, strict: [root: :string]) do
      {opts, [], []} -> {opts[:root] || "..", "master"}
      {opts, [version], []} -> {opts[:root] || "..", version}
      _ -> Mix.raise("usage: mix #{Mix.Task.task_name(__MODULE__)} [version] [--root ..]")
    end
  end
end
