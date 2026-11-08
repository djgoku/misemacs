defmodule Mix.Tasks.Release.Package do
  @shortdoc "Package build/<version>/Emacs.app into dist/<version>/ and self-verify it"
  @moduledoc """
  Turn the relocated and signed `build/<version>/Emacs.app` into the release artifact:
  `dist/<version>/{<asset>, SHASUMS256.txt, upstream-sha.txt}`. Checks the sealed bundle
  without changing it, tars it without xattrs (E7), then verifies the tarball locally.

      mix release.package <version> [<tag>] [--upstream-sha <sha>] [--root ..]

  Without a tag, it packages under today's first tag for the version's channel (dry runs).
  """
  use Mix.Task
  alias Orchestrator.{Cmd, Core.Tag, Manifest, Naming}

  @os "macos"
  @arch "arm64"

  @impl true
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [upstream_sha: :string, root: :string])

    root = opts[:root] || ".."

    {version, tag} =
      case {args, invalid} do
        {[version, tag], []} -> {version, tag}
        {[version], []} -> {version, first_tag(root, version)}
        _ -> Mix.raise("usage: mix release.package <version> [<tag>] [--upstream-sha <sha>]")
      end

    package(root, version, tag, opts[:upstream_sha])
  end

  @doc "Package and self-verify; returns the upstream sha recorded in `upstream-sha.txt`."
  @spec package(Path.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def package(root, version, tag, upstream_sha \\ nil) do
    out = Path.join([root, "build", version])
    app = Path.join(out, "Emacs.app")
    dist = Path.join([root, "dist", version])
    dir = Naming.inner_dir()
    asset = Naming.asset_name(tag, @os, @arch)
    checksums = Naming.checksums_filename()
    bins = Naming.bundle_binaries()

    File.dir?(app) || Mix.raise("#{app} missing; run 'mise run build && mise run relocate' first")

    step("[1] layout check (spec §10; check-only, the bundle is sealed)")

    for bin <- bins, not executable?(Path.join(out, bin)) do
      Mix.raise("missing or non-executable #{bin} in #{out}")
    end

    step("[2] upstream sha")
    upstream_sha = upstream_sha || git_head!(Path.join(out, "src"))

    step("[3] stage + xattr-free tar (E7 / spec §10; stable dir '#{dir}')")
    stage = Path.join(dist, "stage")
    staged_app = Path.join([stage, dir, "Emacs.app"])
    File.rm_rf!(dist)
    File.mkdir_p!(Path.dirname(staged_app))
    copy_app!(app, staged_app)

    Cmd.run!("tar", ["--no-xattrs", "-czf", Path.join("..", asset), dir],
      cd: stage,
      env: [{"COPYFILE_DISABLE", "1"}]
    )

    step("[4] checksums (#{checksums}, bare-basename entries)")
    File.write!(Path.join(dist, checksums), "#{sha256_file(Path.join(dist, asset))}  #{asset}\n")
    Cmd.run!("shasum", ["-a", "256", "-c", checksums], cd: dist)

    step("[5] self-verify: tar listing")
    listing = Cmd.out!("tar", ["-tzf", Path.join(dist, asset)]) |> String.split("\n", trim: true)

    case check_listing(listing, dir, bins) do
      :ok -> :ok
      {:error, msg} -> Mix.raise(msg)
    end

    step("[6] self-verify: extract transport smoke (E7-correct checks)")
    smoke!(Path.join(dist, asset), dir)
    File.rm_rf!(stage)

    File.write!(Path.join(dist, "upstream-sha.txt"), upstream_sha <> "\n")
    step("package: PASS #{Path.join(dist, asset)} + #{checksums} (upstream #{upstream_sha})")
    upstream_sha
  end

  @doc "Every entry under the stable dir, and every bundle binary present."
  @spec check_listing([String.t()], String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def check_listing(listing, dir, bins) do
    entries = MapSet.new(listing)

    cond do
      bad = Enum.find(listing, &(not String.starts_with?(&1, dir <> "/"))) ->
        {:error, "entry outside stable dir: #{bad}"}

      missing = Enum.find(bins, &(not MapSet.member?(entries, "#{dir}/#{&1}"))) ->
        {:error, "#{missing} missing from tarball"}

      true ->
        :ok
    end
  end

  defp first_tag(root, version) do
    v =
      Enum.find(Manifest.versions!(root), &(&1.name == version)) ||
        Mix.raise("no such version #{inspect(version)} in versions.toml")

    Tag.next_tag(v.channel, Date.utc_today() |> Date.to_iso8601(), [])
  end

  defp git_head!(src) do
    File.dir?(Path.join(src, ".git")) || Mix.raise("no #{src} checkout and no --upstream-sha")
    src |> then(&Cmd.out!("git", ["-C", &1, "rev-parse", "HEAD"])) |> String.trim()
  end

  # -c clones on APFS; -p is the fallback on other filesystems.
  defp copy_app!(from, to) do
    case Cmd.capture("cp", ["-Rc", from, to]) do
      {_, 0} ->
        :ok

      _ ->
        File.rm_rf!(to)
        Cmd.run!("cp", ["-Rp", from, to])
    end
  end

  defp smoke!(tarball, dir) do
    tmp = Path.join(System.tmp_dir!(), "package-smoke-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      Cmd.run!("tar", ["-xzf", tarball, "-C", tmp])
      app = Path.join([tmp, dir, "Emacs.app"])

      Cmd.run!(Path.join(app, "Contents/MacOS/Emacs"), [
        "--batch",
        "--eval",
        ~S|(princ (format "ok %s\n" emacs-version))|
      ])

      for sentinel <- ["Contents/Frameworks/libgnutls.30.dylib", "Contents/MacOS/bin/emacsclient"] do
        Cmd.run!("codesign", ["--verify", "--strict", Path.join(app, sentinel)])
      end

      {xattrs, _} = Cmd.capture("find", [tmp, "-exec", "xattr", "-l", "{}", "+"])

      count =
        xattrs |> String.split("\n") |> Enum.count(&(&1 =~ ~r/com\.apple\.(quarantine|cs\.)/))

      count == 0 || Mix.raise("#{count} signature/quarantine xattrs survived the tar")
    after
      File.rm_rf!(tmp)
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp step(msg), do: IO.puts(">> " <> msg)
end
