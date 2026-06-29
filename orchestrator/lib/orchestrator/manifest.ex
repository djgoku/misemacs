defmodule Orchestrator.Manifest do
  @moduledoc """
  The build matrix: versions.toml × targets.toml → job list.
  Adding a version or target is a data edit to those files; no code change.

  INVARIANT: a version's table key (`job.name`) is BOTH the `versions/<name>/` directory
  name AND the join key used everywhere else (`current_states[name]`, the
  `build-manifest.json` `"versions"` map, `Decide.matrix/2`). Keep the table key == the
  git ref where practical (e.g. `[versions."emacs-30.2"]`); `channel` is the short form.

  A `job` is a SUPERSET of what `Decide.plan/4` needs (which takes `%{name,channel,ref}`):
  do not pass a `job` where a `version` is expected, or `:os/:arch/...` leak into the plan.

  Targets are FAIL-CLOSED: a target with no explicit `enabled = true` is disabled.
  """

  @type job :: %{
          name: String.t(),
          channel: String.t(),
          ref: String.t(),
          target: String.t(),
          os: String.t(),
          arch: String.t(),
          runner: String.t(),
          repo: String.t()
        }

  @doc "Pure cross-product of versions × ENABLED targets (fail-closed), sorted for determinism."
  @spec jobs(map(), map(), String.t()) :: [job()]
  def jobs(versions, targets, base) do
    enabled = for {tn, t} <- targets, Map.get(t, "enabled", false), do: {tn, t}

    for {vn, v} <- versions, {tn, t} <- enabled do
      %{
        name: vn,
        channel: v["channel"],
        ref: v["ref"],
        target: tn,
        os: t["os"],
        arch: t["arch"],
        runner: t["runner"],
        repo: Orchestrator.Naming.artifact_repo(base, v["channel"])
      }
    end
    |> Enum.sort_by(&{&1.name, &1.target})
  end

  @doc "Read + parse both TOML manifests into a job list (artifact `base` for repo derivation)."
  @spec load(Path.t(), Path.t(), String.t()) :: {:ok, [job()]} | {:error, term()}
  def load(versions_path, targets_path, base) do
    with {:ok, vbin} <- File.read(versions_path),
         {:ok, tbin} <- File.read(targets_path),
         {:ok, vmap} <- Toml.decode(vbin),
         {:ok, tmap} <- Toml.decode(tbin) do
      {:ok, jobs(Map.get(vmap, "versions", %{}), Map.get(tmap, "targets", %{}), base)}
    end
  end

  @version_input_files ~w(mise.toml pixi.toml pixi.lock)

  @doc """
  The per-version build-input files (relative to repo root) that MUST exist for a version.
  These are exactly the bytes folded into the §8 fingerprint (`mise_toml`, `pixi_toml`,
  `pixi_lock`). "Add a version = data": a new `versions.toml` row needs a `versions/<name>/`
  dir holding these three files — no code change.
  """
  @spec version_input_files(String.t()) :: [String.t()]
  def version_input_files(name) do
    Enum.map(@version_input_files, &Path.join(["versions", name, &1]))
  end

  @doc """
  Returns the version-input files MISSING under `repo_root` for the given version names
  (empty list = all present). Fail-loud helper for the layout-contract test / future CLI.
  """
  @spec missing_version_files(Path.t(), [String.t()]) :: [String.t()]
  def missing_version_files(repo_root, names) do
    for name <- names,
        rel <- version_input_files(name),
        not File.exists?(Path.join(repo_root, rel)),
        do: rel
  end

  @doc """
  The `[%{name, channel, ref}]` version list (for `Core.Decide.plan/4`) parsed from
  `versions.toml` under `root`. Distinct from `jobs/2`, which crosses in targets.
  """
  @spec versions!(Path.t()) :: [%{name: String.t(), channel: String.t(), ref: String.t()}]
  def versions!(root) do
    {:ok, map} = Toml.decode(File.read!(Path.join(root, "versions.toml")))

    for {name, v} <- Map.get(map, "versions", %{}) do
      %{name: name, channel: v["channel"], ref: v["ref"]}
    end
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Merge per-cell single-version fragments into the prior `latest` manifest (spec §4.4).
  Fragment version entries win; `prior` nil ⇒ start empty (first run). Always schema 1.
  """
  @spec merge(map() | nil, [map()]) :: map()
  def merge(prior, fragments) do
    base = (prior && Map.get(prior, "versions", %{})) || %{}

    merged =
      Enum.reduce(fragments, base, fn frag, acc ->
        Map.merge(acc, Map.get(frag, "versions", %{}))
      end)

    %{"schema" => 1, "versions" => merged}
  end
end
