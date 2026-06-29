defmodule Mix.Tasks.Orchestrate.Decide do
  @shortdoc "Emit the dynamic build matrix + gate flags (spec §4.2)"
  @moduledoc """
  The decide-gate brain. Modes: `detect` (compare upstream+inputs vs the latest manifest),
  `force` (one ref), `dry-run` (all enabled, PR). Prints `key=value` lines (matrix JSON, any,
  dry_run) for `>> "$GITHUB_OUTPUT"`. IO (git ls-remote / gh / clang) is gathered here and
  handed to the pure `Orchestrator.Orchestrate`.

      mix orchestrate.decide --repo <owner/repo> --date 2026-06-13 --mode detect [--root ..]
      mix orchestrate.decide --mode force --force-version master --date <d>
      mix orchestrate.decide --mode dry-run --date <d>
  """
  use Mix.Task
  alias Orchestrator.{Manifest, Orchestrate, Core.Hash}

  @switches [repo: :string, date: :string, mode: :string, force_version: :string, root: :string]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    opts |> Map.new() |> main(default_deps())
  end

  @doc "exec + emit; `deps` injectable for tests."
  def main(opts, deps) do
    out = exec(opts, deps)
    emit(out)
    out
  end

  @doc "Gather IO (detect only) + shape outputs."
  def exec(opts, deps \\ default_deps()) do
    root = opts[:root] || ".."
    date = fetch!(opts, :date)
    mode = fetch!(opts, :mode)
    versions = Manifest.versions!(root)
    {:ok, jobs} =
      Manifest.load(
        Path.join(root, "versions.toml"),
        Path.join(root, "targets.toml"),
        artifact_base(opts)
      )

    {states, manifest} =
      if mode == "detect" do
        clt = deps.toolchain.()
        {current_states(versions, root, clt, deps.upstream),
         combined_manifest(versions, artifact_base(opts), deps.releases)}
      else
        {%{}, nil}
      end

    Orchestrate.decide_outputs(mode, versions, jobs, states, manifest, date, opts[:force_version])
  end

  defp current_states(versions, root, clt, resolve) do
    toolchain_hash =
      Hash.toolchain_hash(
        File.read!(Path.join(root, "mise.toml")),
        File.read!(Path.join(root, "mise.lock")),
        clt
      )

    for v <- versions, into: %{} do
      [mise_toml, pixi_toml, pixi_lock] =
        v.name |> Manifest.version_input_files() |> Enum.map(&File.read!(Path.join(root, &1)))

      sha = resolve.(v.ref)

      hash =
        Hash.version_fingerprint(%{
          toolchain_hash: toolchain_hash,
          upstream_sha: sha || "",
          mise_toml: mise_toml,
          pixi_toml: pixi_toml,
          pixi_lock: pixi_lock
        })

      {v.name, %{upstream_sha: sha, inputs_hash: hash}}
    end
  end

  defp emit(%{matrix: matrix, any: any, dry_run: dry_run}) do
    IO.puts("matrix=#{JSON.encode!(matrix)}")
    IO.puts("any=#{any}")
    IO.puts("dry_run=#{dry_run}")
  end

  def default_deps do
    %{
      upstream: &Orchestrator.Upstream.GitLsRemote.resolve/1,
      releases: &Orchestrator.Releases.Gh.last_manifest/1,
      toolchain: &Orchestrator.Toolchain.Macos.clt_fingerprint/0
    }
  end

  defp fetch!(opts, key),
    do: opts[key] || Mix.raise("missing --#{key |> Atom.to_string() |> String.replace("_", "-")}")

  # Artifact-repo base: env override (lab/CI) else the SOURCE repo string itself
  # (djgoku/misemacs -> djgoku/misemacs-emacs-<channel>). Default keeps non-detect modes working.
  defp artifact_base(opts) do
    System.get_env("MISEMACS_ARTIFACT_BASE") || opts[:repo] || "djgoku/misemacs"
  end

  # Read each DISTINCT channel's manifest from its artifact repo; merge :ok ones'
  # "versions" maps into one combined manifest (the shape Decide.plan consumes via
  # previous_state). :empty -> no entry (first run for that channel). :error -> abort.
  defp combined_manifest(versions, base, read) do
    versions
    |> Enum.map(& &1.channel)
    |> Enum.uniq()
    |> Enum.reduce(%{"schema" => 1, "versions" => %{}}, fn channel, acc ->
      repo = Orchestrator.Naming.artifact_repo(base, channel)

      case read.(repo) do
        {:ok, %{"versions" => v}} -> update_in(acc, ["versions"], &Map.merge(&1, v))
        :empty -> acc
        {:error, reason} -> Mix.raise("decide preflight: #{repo} unreadable: #{inspect(reason)}")
      end
    end)
    |> case do
      %{"versions" => v} when map_size(v) == 0 -> nil
      combined -> combined
    end
  end
end
