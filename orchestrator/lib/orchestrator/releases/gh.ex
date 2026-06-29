defmodule Orchestrator.Releases.Gh do
  @moduledoc """
  Default `Orchestrator.Releases` — fetch `build-manifest.json` from the lexical-newest git
  tag in the per-channel release repo via `gh`. Three-way result:

    * `{:ok, manifest}`   — newest tag exists and carries a valid manifest
    * `:empty`            — repo is reachable but has no tags (genuine first run)
    * `{:error, reason}`  — repo unreachable / auth failure / newest tag has no/corrupt manifest

  The lexical-newest tag is the sole authority (matches aqua's `github_tag` resolution). No
  scan-back to older tags: if the newest tag lacks a manifest, the caller must treat it as an
  error rather than silently falling back to stale state.
  """
  @behaviour Orchestrator.Releases
  @asset "build-manifest.json"

  @impl true
  def last_manifest(repo) do
    classify(list_tags(repo), &fetch(repo, &1))
  end

  @doc """
  Pure decision over a `list_tags` result + a `fetch.(tag)` fun. ONLY the lexical-newest
  tag is authoritative (matches aqua's `github_tag` resolution; the per-channel repo holds
  one channel so the max is unambiguous):
    * `{:error, reason}`              -> `{:error, reason}` (repo unreachable/auth failure)
    * `{:ok, []}`                     -> `:empty` (reachable, no releases = first run)
    * `{:ok, tags}`, newest has mfst  -> `{:ok, manifest}`
    * `{:ok, tags}`, newest lacks it  -> `{:error, {:no_manifest_on_newest, tag}}`
  """
  @spec classify({:ok, [String.t()]} | {:error, term()}, (String.t() -> map() | nil)) ::
          {:ok, map()} | :empty | {:error, term()}
  def classify({:error, reason}, _fetch), do: {:error, reason}
  def classify({:ok, []}, _fetch), do: :empty

  def classify({:ok, tags}, fetch) do
    newest = Enum.max(tags)

    case fetch.(newest) do
      nil -> {:error, {:no_manifest_on_newest, newest}}
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
