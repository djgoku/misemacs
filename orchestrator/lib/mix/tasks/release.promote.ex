defmodule Mix.Tasks.Release.Promote do
  @shortdoc "Verify Packslip signatures, attach build-manifest.json, flip the Latest marker"
  @moduledoc """
      mix release.promote --repo <owner/repo> --tag <tag> --channel <channel>
        [--version master] [--manifest <path>] [--attach "t1 t2 ..."] [--root ..]

  Verifies every signed archive first, then attaches `build-manifest.json` to `<tag>` and each
  `--attach` tag (`--clobber`, idempotent, P6), then marks `<tag>` Latest (P3). Rerun after
  any failure. Without `--manifest` it builds a single-version manifest from `dist/<version>/`.
  """
  use Mix.Task
  alias Orchestrator.{Cmd, Naming}

  @switches [
    repo: :string,
    tag: :string,
    channel: :string,
    version: :string,
    manifest: :string,
    attach: :string,
    root: :string
  ]
  @bundle "packslip.sigstore.json"
  @issuer "https://token.actions.githubusercontent.com"
  @sign_attempts 60
  @sign_interval_ms 10_000

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    root = opts[:root] || ".."

    {repo, tag, channel} =
      case {opts[:repo], opts[:tag], opts[:channel]} do
        {r, t, c} when is_binary(r) and is_binary(t) and is_binary(c) ->
          {r, t, c}

        _ ->
          Mix.raise("usage: mix release.promote --repo <owner/repo> --tag <tag> --channel <ch>")
      end

    expected = Naming.artifact_repo(Naming.artifact_base(), channel)

    if repo != expected do
      Mix.raise(
        "promote --repo '#{repo}' / --tag '#{tag}': expected '#{expected}' (channel '#{channel}')"
      )
    end

    tags = Enum.uniq([tag | String.split(opts[:attach] || "")])
    Enum.each(tags, &verify_signed!(repo, &1))

    manifest =
      case opts[:manifest] do
        nil -> local_manifest!(root, opts[:version] || "master", tag, repo)
        path -> if File.regular?(path), do: path, else: Mix.raise("--manifest #{path} not found")
      end

    for t <- tags do
      IO.puts(">> attach manifest to #{t} (idempotent)")
      Cmd.run!("gh", ["release", "upload", t, manifest, "--repo", repo, "--clobber"])
    end

    IO.puts(">> flip Latest marker to #{tag}")
    Cmd.run!("gh", ["release", "edit", tag, "--repo", repo, "--latest"])

    IO.puts(
      ">> promote: PASS #{tag} is Latest on #{repo}; manifest attached to #{Enum.join(tags, " ")}"
    )
  end

  @doc "The Packslip statement names this repo's project and this exact release."
  @spec statement_matches?(map(), String.t(), String.t()) :: boolean()
  def statement_matches?(statement, repo, "v" <> version = tag) do
    match?(
      %{
        "predicate" => %{
          "project" => project,
          "version" => ^version,
          "source" => %{"repo" => source_repo, "tag" => ^tag}
        }
      }
      when project == "github.com/" <> repo and source_repo == "https://github.com/" <> repo,
      statement
    )
  end

  def statement_matches?(_statement, _repo, _tag), do: false

  # The artifact repo signs asynchronously after `gh release create`; wait for its bundle.
  defp verify_signed!(repo, tag) do
    tag =~ ~r/\Av\d+\.\d+\.\d+\z/ || Mix.raise("invalid Packslip tag '#{tag}'")
    wait_for_bundle!(repo, tag, @sign_attempts)

    dir = Path.join(System.tmp_dir!(), "promote-#{System.unique_integer([:positive])}")
    asset = Naming.asset_name(tag, "macos", "arm64")

    try do
      Cmd.run!("gh", [
        "release",
        "download",
        tag,
        "--repo",
        repo,
        "--dir",
        dir,
        "--pattern",
        @bundle,
        "--pattern",
        asset
      ])

      bundle = Path.join(dir, @bundle)
      archive = Path.join(dir, asset)

      if not (non_empty?(bundle) and non_empty?(archive)) do
        Mix.raise("#{repo}@#{tag} is missing its Packslip bundle or archive")
      end

      IO.puts(">> verify #{repo}@#{tag} signature, signer, and archive digest")

      Cmd.run!("packslip", [
        "verify",
        bundle,
        "--identity",
        "https://github.com/#{repo}/.github/workflows/packslip.yml@refs/tags/#{tag}",
        "--issuer",
        @issuer,
        "--artifact",
        archive
      ])

      statement = Cmd.out!("packslip", ["show", bundle]) |> JSON.decode!()

      statement_matches?(statement, repo, tag) ||
        Mix.raise("#{repo}@#{tag} Packslip identifies a different project or release")
    after
      File.rm_rf!(dir)
    end
  end

  defp wait_for_bundle!(repo, tag, 0),
    do:
      Mix.raise(
        "#{repo}@#{tag} has no signed Packslip after #{div(@sign_attempts * @sign_interval_ms, 60_000)} minutes"
      )

  defp wait_for_bundle!(repo, tag, attempts) do
    {out, status} =
      Cmd.capture("gh", ["release", "view", tag, "--repo", repo, "--json", "assets"])

    signed? =
      case {status, JSON.decode(out)} do
        {0, {:ok, %{"assets" => assets}}} -> Enum.any?(assets, &(&1["name"] == @bundle))
        _ -> false
      end

    if not signed? do
      Process.sleep(@sign_interval_ms)
      wait_for_bundle!(repo, tag, attempts - 1)
    end
  end

  # Phase-4 local path: the single-version manifest from dist/<version>/.
  defp local_manifest!(root, version, tag, repo) do
    dist = Path.join([root, "dist", version])
    sha_file = Path.join(dist, "upstream-sha.txt")
    File.regular?(sha_file) || Mix.raise("#{sha_file} missing; run `mise run package` first")

    asset = Path.join(dist, Naming.asset_name(tag, "macos", "arm64"))
    File.regular?(asset) || Mix.raise("#{asset} missing; does --tag match the packaged artifact?")

    out = Path.join(dist, "build-manifest.json")

    Mix.Task.rerun("release.manifest", [
      "--version",
      version,
      "--tag",
      tag,
      "--upstream-sha",
      sha_file |> File.read!() |> String.trim(),
      "--root",
      root,
      "--out",
      out
    ])

    case out |> File.read!() |> JSON.decode!() do
      %{"repo" => manifest_repo} when manifest_repo != repo ->
        Mix.raise(
          "manifest repo '#{manifest_repo}' (from --version '#{version}') != --repo '#{repo}'"
        )

      _ ->
        out
    end
  end

  defp non_empty?(path), do: match?({:ok, %File.Stat{size: s}} when s > 0, File.stat(path))
end
