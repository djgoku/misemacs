defmodule Mix.Tasks.Release.Publish do
  @shortdoc "Compute the next tag, package, and create the GitHub release (never Latest)"
  @moduledoc """
      mix release.publish --repo <owner/repo> [--version master] [--root ..]

  The channel comes from `versions.toml`. Each attempt snapshots the repo's tags, computes the
  next tag (`Core.Tag`), packages, and runs `gh release create --latest=false` (P3/G1: flipping
  Latest is promote's job). A tag collision (P1) re-snapshots and retries, up to 3 attempts.
  """
  use Mix.Task
  alias Orchestrator.{Cmd, Core.Tag, Manifest, Naming}

  @attempts 3
  @template "templates/artifact-packslip.yml"

  @impl true
  def run(argv) do
    {opts, [], []} =
      OptionParser.parse(argv, strict: [repo: :string, version: :string, root: :string])

    root = opts[:root] || ".."
    repo = opts[:repo] || Mix.raise("--repo is required (G8: no default repo)")
    version = opts[:version] || "master"

    v =
      Enum.find(Manifest.versions!(root), &(&1.name == version)) ||
        Mix.raise("no such version #{inspect(version)} in versions.toml")

    # Data validation, not an auth gate (spec D2/§4.5). A derived "<base>-emacs-<ch>" name can
    # never equal the bare source repo, so this also refuses publishing to djgoku/misemacs.
    expected = Naming.artifact_repo(Naming.artifact_base(), v.channel)

    if repo != expected do
      Mix.raise(
        "--repo '#{repo}' != expected artifact repo '#{expected}' for channel '#{v.channel}'"
      )
    end

    check_packslip_workflow!(root, repo)
    date = Date.utc_today() |> Date.to_iso8601()
    notes_base = "#{v.channel} @ #{Naming.upstream(v.upstream)}/commit/"
    attempt(root, repo, v, date, notes_base, 1)
  end

  @doc "Tag names from `git ls-remote --tags` output, peeled `^{}` duplicates folded."
  @spec ls_remote_tags(String.t()) :: [String.t()]
  def ls_remote_tags(out) do
    for line <- String.split(out, "\n", trim: true),
        [_sha, "refs/tags/" <> name] <- [String.split(line, "\t")],
        uniq: true,
        do: String.replace_suffix(name, "^{}", "")
  end

  @doc "`git hash-object` of the given bytes: the blob sha the GitHub contents API reports."
  @spec git_blob_sha(binary()) :: String.t()
  def git_blob_sha(bytes) do
    :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(bytes)), 0, bytes])
    |> Base.encode16(case: :lower)
  end

  defp attempt(_root, _repo, _v, _date, _notes, n) when n > @attempts,
    do: Mix.raise("#{@attempts} tag collisions in a row; investigate the snapshot")

  defp attempt(root, repo, v, date, notes_base, n) do
    IO.puts(">> [attempt #{n}] tag snapshot")
    tag = Tag.next_tag(v.channel, date, snapshot!(repo))

    IO.puts(">> package #{v.name} as #{tag}")
    sha = Mix.Tasks.Release.Package.package(root, v.name, tag)
    dist = Path.join([root, "dist", v.name])

    IO.puts(">> gh release create #{tag} on #{repo} (--latest=false, G1)")

    args =
      ["release", "create", tag, "--repo", repo, "--title", tag, "--latest=false"] ++
        ["--notes", notes_base <> sha] ++
        [
          Path.join(dist, Naming.asset_name(tag, "macos", "arm64")),
          Path.join(dist, Naming.checksums_filename())
        ]

    case Cmd.capture("gh", args) do
      {out, 0} ->
        IO.puts(out)
        File.write!(Path.join(dist, "published-tag.txt"), tag <> "\n")
        IO.puts(">> publish: PASS #{tag} on #{repo} (not latest; promote is a separate step)")

      {out, _} ->
        if out =~ "already exists" do
          IO.puts(">> tag collision (P1): #{String.trim(out)}; recomputing")
          attempt(root, repo, v, date, notes_base, n + 1)
        else
          Mix.raise("""
          gh release create failed: #{String.trim(out)}
          (partial release? inspect with: gh release view #{tag} --repo #{repo};
           clean up with: gh release delete #{tag} --repo #{repo} --yes [--cleanup-tag])
          """)
        end
    end
  end

  # Union of git tags and release names (drafts hold a name without a tag, P4). Either source
  # failing raises, so a partial snapshot can never let `gh release create` adopt a
  # dangling tag (P2) instead of colliding (P1).
  defp snapshot!(repo) do
    tags = ls_remote_tags(Cmd.out!("git", ["ls-remote", "--tags", "https://github.com/#{repo}"]))

    releases =
      Cmd.out!("gh", ["release", "list", "--repo", repo, "--limit", "1000", "--json", "tagName"])
      |> JSON.decode!()
      |> Enum.map(& &1["tagName"])

    Enum.uniq(tags ++ releases)
  end

  # Packslip must be signed by the artifact repo's own workflow; refuse before any public
  # release when the installed workflow differs from the template.
  defp check_packslip_workflow!(root, repo) do
    expected = root |> Path.join(@template) |> File.read!() |> git_blob_sha()
    path = "repos/#{repo}/contents/.github/workflows/packslip.yml"

    case Cmd.capture("gh", ["api", path]) do
      {out, 0} ->
        JSON.decode!(out)["sha"] == expected ||
          Mix.raise("#{repo} Packslip workflow differs from #{@template}")

      _ ->
        Mix.raise("install #{@template} as .github/workflows/packslip.yml in #{repo} first")
    end
  end
end
