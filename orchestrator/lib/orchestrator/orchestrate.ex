defmodule Orchestrator.Orchestrate do
  @moduledoc """
  Pure shaping for the decide/finalize jobs (spec §4.2/§4.4): wraps `Core.{Decide,Latest}` +
  `Manifest.merge` into the job-output / manifest shapes the workflow consumes. No IO — the
  mix tasks do the git/gh/clang IO and hand the gathered data here.
  """
  alias Orchestrator.Core.{Decide, Latest}
  alias Orchestrator.Core.Decide.Plan
  alias Orchestrator.Manifest

  @type outputs :: %{matrix: %{String.t() => [map()]}, any: boolean(), dry_run: boolean()}

  @doc "Shape the decide job outputs for a mode. `states`/`manifest` are used only in `detect`."
  @spec decide_outputs(
          String.t(),
          [map()],
          [map()],
          map(),
          map() | nil,
          String.t(),
          String.t() | nil
        ) :: outputs()
  def decide_outputs(mode, versions, jobs, states, manifest, date, force_version) do
    plan =
      case mode do
        "detect" -> Decide.plan(versions, states, manifest, date)
        "force" -> Decide.force(versions, force_version, date)
        "dry-run" -> all(versions, date)
      end

    cells = Decide.matrix(plan, jobs)
    %{matrix: %{"include" => cells}, any: cells != [], dry_run: mode == "dry-run"}
  end

  defp all(versions, date) do
    %Plan{
      date: date,
      build:
        Enum.map(versions, &%{name: &1.name, channel: &1.channel, reason: :dry_run, state: %{}}),
      skip: []
    }
  end

  @doc """
  Finalize ONE artifact repo: keep only fragments whose `"repo"` == `repo`, merge them
  into `prior` (that channel's prior manifest), and pick the newest released tag.
  Returns `built_tags` (this repo's released tags, ascending) for the manifest-attach loop.
  """
  @spec finalize_outputs(map() | nil, [map()], String.t()) :: %{
          manifest: map(),
          latest_tag: String.t() | nil,
          built_tags: [String.t()]
        }
  def finalize_outputs(prior, fragments, repo) do
    mine = Enum.filter(fragments, &(Map.get(&1, "repo") == repo))

    tags =
      for f <- mine, {_v, e} <- Map.get(f, "versions", %{}), do: e["released_tag"]

    tags = tags |> Enum.reject(&is_nil/1) |> Enum.sort()

    latest =
      case Latest.latest_target(tags) do
        {:set, tag} -> tag
        :unchanged -> nil
      end

    %{manifest: Manifest.merge(prior, mine), latest_tag: latest, built_tags: tags}
  end
end
