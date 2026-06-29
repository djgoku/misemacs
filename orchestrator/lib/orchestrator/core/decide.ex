defmodule Orchestrator.Core.Decide do
  @moduledoc """
  Pure release planning + matrix join. No IO.

  `plan/4` decides which versions build (the cadence gate: empty `build` ⇒ release
  nothing). `matrix/2` joins the plan against the full job list by `:name` to produce the
  per-cell build matrix the Phase-5 decide-job emits (wrap as `{"include": matrix}` for
  GitHub Actions `strategy.matrix`). Tags are computed per-cell at PUBLISH time
  (`Core.Tag`), never baked into the matrix here.
  """
  alias Orchestrator.Core.Detect

  defmodule Plan do
    @enforce_keys [:date]
    defstruct build: [], skip: [], date: nil

    @type build_entry :: %{name: String.t(), channel: String.t(), reason: atom(), state: map()}
    @type skip_entry :: %{name: String.t(), reason: atom()}
    @type t :: %__MODULE__{build: [build_entry()], skip: [skip_entry()], date: String.t()}
  end

  @doc """
  Build the release plan (build-order preserved — `Core.Latest` relies on it).

    * `versions`        — [%{name, channel, ref}]
    * `current_states`  — %{name => %{upstream_sha, inputs_hash}} (must contain every version; missing ⇒ raises)
    * `last_manifest`   — %{"versions" => %{name => %{"upstream_sha", "inputs_hash"}}} | nil
    * `date`            — "YYYY-MM-DD"
  """
  @spec plan([map()], map(), map() | nil, String.t()) :: Plan.t()
  def plan(versions, current_states, last_manifest, date) do
    {build, skip} =
      Enum.reduce(versions, {[], []}, fn v, {b, s} ->
        current = Map.fetch!(current_states, v.name)

        case Detect.changed?(current, previous_state(last_manifest, v.name)) do
          {true, reason} ->
            {[%{name: v.name, channel: v.channel, reason: reason, state: current} | b], s}

          {false, reason} ->
            {b, [%{name: v.name, reason: reason} | s]}
        end
      end)

    %Plan{date: date, build: Enum.reverse(build), skip: Enum.reverse(skip)}
  end

  @doc """
  Force a single version into `build` (reason `:forced`), bypassing detection — the
  `workflow_dispatch(force_version)` path (spec §4.2). Raises if the version is unknown.
  `state` is `%{}` (a forced build's cell resolves upstream itself).
  """
  @spec force([map()], String.t(), String.t()) :: Plan.t()
  def force(versions, version_name, date) do
    v =
      Enum.find(versions, &(&1.name == version_name)) ||
        raise ArgumentError, "force_version #{inspect(version_name)} not in versions.toml"

    %Plan{
      date: date,
      build: [%{name: v.name, channel: v.channel, reason: :forced, state: %{}}],
      skip: for(o <- versions, o.name != version_name, do: %{name: o.name, reason: :not_forced})
    }
  end

  @doc """
  Join a plan against the full job list (`Orchestrator.Manifest.jobs/3` output) by
  `:name`, yielding the per-cell build matrix (changed versions × their targets). Only
  jobs whose version is in `plan.build` survive; job order is preserved.
  """
  @spec matrix(Plan.t(), [map()]) :: [map()]
  def matrix(%Plan{build: build}, jobs) do
    names = MapSet.new(build, & &1.name)
    Enum.filter(jobs, &MapSet.member?(names, &1.name))
  end

  defp previous_state(nil, _name), do: nil

  defp previous_state(manifest, name) do
    case get_in(manifest, ["versions", name]) do
      nil -> nil
      e -> %{upstream_sha: e["upstream_sha"], inputs_hash: e["inputs_hash"]}
    end
  end
end
