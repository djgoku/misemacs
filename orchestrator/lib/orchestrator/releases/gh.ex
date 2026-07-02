defmodule Orchestrator.Releases.Gh do
  @moduledoc """
  Default `Orchestrator.Releases` — fetch `build-manifest.json` from the per-channel release
  repo via `gh`, scanning tags newest-first (lexical-desc, matches aqua's `github_tag`
  resolution). Three-way result:

    * `{:ok, manifest}`   — a recent tag carries a valid manifest (first hit of the scan)
    * `:empty`            — repo reachable but no tags, or none of the newest `@scan_back`
                            carries a manifest (first run / only in-flight releases)
    * `{:error, reason}`  — the tag LIST fetch failed (repo unreachable / auth failure)

  The bounded scan-back exists because a release is published BEFORE finalize attaches its
  manifest: the newest tag may legitimately have none yet, and treating that as an error
  would deadlock the run that published it (see `classify/2` and design §4.7).
  """
  @behaviour Orchestrator.Releases
  @asset "build-manifest.json"

  @impl true
  def last_manifest(repo) do
    classify(list_tags(repo), &fetch(repo, &1))
  end

  # Bound the newest-first scan: a healthy repo's newest tag carries the manifest (1 fetch);
  # this only scans further past manifest-LESS in-flight releases (published this run, manifest
  # attached later by finalize) — never the whole list.
  @scan_back 10

  @doc """
  Pure decision over a `list_tags` result + a `fetch.(tag)` fun. Scans the newest tags first
  (lexical-desc) and returns the FIRST one that carries a `build-manifest.json` — tolerating
  manifest-less releases (a release is published BEFORE finalize attaches its manifest, so the
  lexical-newest tag during/after a run may legitimately have none yet):
    * `{:error, reason}`        -> `{:error, reason}` (the LIST fetch failed = repo unreachable/auth)
    * `{:ok, []}`               -> `:empty` (reachable, no releases = first run)
    * `{:ok, tags}`, a recent tag has a manifest -> `{:ok, manifest}`
    * `{:ok, tags}`, none of the newest #{@scan_back} has one -> `:empty` (treat as no-prior /
      first-run; callers rebuild, which self-heals — no hard deadlock on a manifest-less release)
  """
  @spec classify({:ok, [String.t()]} | {:error, term()}, (String.t() -> map() | nil)) ::
          {:ok, map()} | :empty | {:error, term()}
  def classify({:error, reason}, _fetch), do: {:error, reason}
  def classify({:ok, []}, _fetch), do: :empty

  def classify({:ok, tags}, fetch) do
    tags
    # Lexical-desc == aqua's github_tag order (incl. the `.10 < .9` quirk — see Core.Latest).
    |> Enum.sort(:desc)
    |> Enum.take(@scan_back)
    |> Enum.find_value(fn tag -> fetch.(tag) end)
    |> case do
      nil -> :empty
      manifest -> {:ok, manifest}
    end
  end

  # IO: list the repo's git tags (newest page). {:ok, [name]} on success (possibly empty),
  # {:error, _} on gh failure. The GitHub tags API returns the newest 100; the per-channel
  # repo's global-newest is therefore present and `classify` takes the lexical max.
  defp list_tags(repo) do
    case gh(["api", "repos/#{repo}/tags?per_page=100", "--jq", ".[].name"]) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  # nil conflates "no manifest on this tag" with a transient `gh release download` failure —
  # deliberate: worst case the scan sees no prior state and rebuilds (safe, self-healing).
  # The tag LIST above is the decisive reachability/auth signal, per the design (§4.7).
  defp fetch(repo, tag) do
    dir = Path.join(System.tmp_dir!(), "rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      case gh(["release", "download", tag, "--repo", repo, "--pattern", @asset, "--dir", dir]) do
        {_, 0} -> dir |> Path.join(@asset) |> File.read() |> parse_manifest()
        _ -> nil
      end
    after
      File.rm_rf!(dir)
    end
  end

  @doc "Pure: parse a `{:ok, json}`/`{:error, _}`/json string into a manifest map; nil otherwise."
  def parse_manifest({:ok, json}), do: parse_manifest(json)
  def parse_manifest({:error, _}), do: nil

  def parse_manifest(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{"versions" => _} = m} -> m
      _ -> nil
    end
  end

  defp gh(args) do
    System.cmd("gh", args, stderr_to_stdout: true)
  rescue
    ErlangError -> {"", 1}
  end
end
