defmodule Mix.Tasks.Orchestrate.Finalize do
  @shortdoc "Merge per-cell manifest fragments + pick the latest tag (spec §4.4)"
  @moduledoc """
  Reads this run's `manifest-*` fragments (a dir of single-version build-manifest.json),
  merges them into the prior `latest` manifest (`Releases`), writes the merged
  `build-manifest.json` to `--out`, and prints `latest_tag=<tag>` (empty ⇒ nothing to
  finalize, no flip) and `built_tags=<space-separated>` (every released tag this run). The
  bash `pipeline/promote --manifest --attach "$built_tags"` then attaches the merged manifest
  to EVERY built release and flips Latest to `latest_tag`.

      mix orchestrate.finalize --repo <owner/repo> --fragments <dir> --out <path>
  """
  use Mix.Task
  alias Orchestrator.Orchestrate

  @switches [repo: :string, fragments: :string, out: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    main(Map.new(opts), default_deps())
  end

  @doc "exec + emit; `deps` injectable for tests."
  def main(opts, deps) do
    res = exec(opts, deps)
    emit(res, opts[:out])
    res
  end

  def exec(opts, deps \\ default_deps()) do
    fragments = read_fragments(opts[:fragments] || ".")
    prior = deps.releases.(opts[:repo])
    tags = built_tags(fragments)
    Orchestrate.finalize_outputs(prior, fragments, tags) |> Map.put(:built_tags, tags)
  end

  defp read_fragments(dir) do
    dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
  end

  # built tags in fragment order (v1: single). Multi-version recency ordering = Phase-6 refinement.
  defp built_tags(fragments) do
    for f <- fragments, {_v, e} <- Map.get(f, "versions", %{}), do: e["released_tag"]
  end

  defp emit(%{manifest: manifest, latest_tag: tag, built_tags: tags}, out) do
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, JSON.encode!(manifest) <> "\n")
    IO.puts("latest_tag=#{tag || ""}")
    # Every released tag this run, so the finalize job attaches the merged manifest to EACH
    # release (self-describing), not just Latest. promote consumes this via --attach.
    IO.puts("built_tags=#{tags |> Enum.reject(&is_nil/1) |> Enum.join(" ")}")
  end

  def default_deps, do: %{releases: &Orchestrator.Releases.Gh.last_manifest/1}
end
