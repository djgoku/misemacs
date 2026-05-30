# should_release.exs — decide whether a flavor needs a build+release by
# comparing its current inputs-hash to the most recent release's recorded
# inputs.sha256. Prints `changed=true` or `changed=false` to stdout (the
# workflow appends it to $GITHUB_OUTPUT); human-readable log goes to stderr.
#
# Usage: should_release.exs <flavor> [--force] [--version V]
# Env:   GITHUB_REPOSITORY (optional — when set, passed to gh as --repo),
#        GH_TOKEN (for gh auth in CI).
Code.require_file("misemacs_lib.exs", __DIR__)

defmodule ShouldRelease do
  alias Misemacs.Lib

  def main(argv) do
    {flavor, opts} = parse(argv, nil, %{force: false, version_given: false})
    root = Path.expand(Path.join(__DIR__, "../.."))

    cur = Lib.inputs_hash(root, flavor)
    if cur == "", do: Lib.die("should-release: empty inputs-hash for #{flavor}")
    IO.puts(:stderr, "current inputs-hash: #{cur}")

    prev_tag = latest_release_tag(flavor)
    prev = if prev_tag, do: download_prev_hash(prev_tag), else: nil

    IO.puts(
      :stderr,
      if(prev_tag,
        do: "latest #{flavor} release: #{prev_tag} (inputs-hash: #{prev || "<none>"})",
        else: "no prior #{flavor}-* release"
      )
    )

    changed = Lib.decide(cur, prev, opts)

    unless changed do
      IO.puts(:stderr, "::notice::#{flavor}: inputs unchanged since #{prev_tag} — nothing to build or release.")
    end

    IO.puts("changed=#{changed}")
  end

  # ---- arg parsing ----
  defp parse([], flavor, opts) when is_binary(flavor), do: {flavor, opts}
  defp parse([], nil, _opts), do: Misemacs.Lib.die("usage: should_release.exs <flavor> [--force] [--version V]")
  defp parse(["--force" | rest], flavor, opts), do: parse(rest, flavor, %{opts | force: true})
  defp parse(["--version", v | rest], flavor, opts) when v != "", do: parse(rest, flavor, %{opts | version_given: true})
  defp parse(["--version", _ | rest], flavor, opts), do: parse(rest, flavor, opts)
  defp parse([arg | rest], nil, opts), do: parse(rest, arg, opts)
  defp parse([_ | rest], flavor, opts), do: parse(rest, flavor, opts)

  # ---- gh helpers ----
  defp gh_repo_args do
    case System.get_env("GITHUB_REPOSITORY") do
      repo when is_binary(repo) and repo != "" -> ["--repo", repo]
      _ -> []
    end
  end

  defp latest_release_tag(flavor) do
    json = Lib.sh("gh", ["release", "list"] ++ gh_repo_args() ++ ["--json", "tagName", "--limit", "1000"])

    json
    |> :json.decode()
    |> Enum.map(&Map.get(&1, "tagName"))
    |> Lib.latest_tag(flavor)
  end

  defp download_prev_hash(tag) do
    dir = Path.join(System.tmp_dir!(), "misemacs-prev-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      args = ["release", "download", tag] ++ gh_repo_args() ++ ["--pattern", "inputs.sha256", "--dir", dir]

      case System.cmd("gh", args, stderr_to_stdout: true) do
        {_, 0} ->
          path = Path.join(dir, "inputs.sha256")
          if File.exists?(path), do: path |> File.read!() |> String.trim(), else: nil

        # Older releases may not carry the asset; treat as "no prev" (rebuild).
        {_, _} ->
          nil
      end
    after
      File.rm_rf!(dir)
    end
  end
end

ShouldRelease.main(System.argv())
