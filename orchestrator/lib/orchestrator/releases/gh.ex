defmodule Orchestrator.Releases.Gh do
  @moduledoc """
  Default `Orchestrator.Releases` — fetch `build-manifest.json` from the `latest` release via
  `gh`; if absent/corrupt, scan the most-recent releases (newest first). `nil` when none.
  """
  @behaviour Orchestrator.Releases
  @asset "build-manifest.json"
  @scan 10

  @impl true
  def last_manifest(repo) do
    [latest_tag(repo) | recent_tags(repo)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(&fetch(repo, &1))
  end

  defp latest_tag(repo) do
    case gh(["release", "view", "--repo", repo, "--json", "tagName", "--jq", ".tagName"]) do
      {out, 0} -> trim_nil(out)
      _ -> nil
    end
  end

  defp recent_tags(repo) do
    case gh(["release", "list", "--repo", repo, "--limit", "#{@scan}", "--json", "tagName", "--jq", ".[].tagName"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
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

  defp trim_nil(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp gh(args) do
    System.cmd("gh", args, stderr_to_stdout: true)
  rescue
    ErlangError -> {"", 1}
  end
end
