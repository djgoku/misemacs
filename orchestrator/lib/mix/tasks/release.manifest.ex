defmodule Mix.Tasks.Release.Manifest do
  @shortdoc "Write the schema-1 build-manifest.json for one released version"
  @moduledoc """
  Emits the §7.2 state manifest using the SAME `Core.Hash` §8 fingerprint that
  Phase 5's detect will recompute (over the same input set — Decision E extends
  `toolchain_hash` there). Network-free; the only IO is reading the committed
  input files and writing `--out`.

      mix release.manifest --version master --tag <tag> --upstream-sha <sha> \\
                           --out ../dist/master/build-manifest.json [--root ..]
  """
  use Mix.Task
  alias Orchestrator.{Core.Hash, Manifest, Naming}

  @switches [
    version: :string,
    tag: :string,
    upstream_sha: :string,
    out: :string,
    root: :string,
    clt_fingerprint: :string,
    artifact_base: :string
  ]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    root = opts[:root] || ".."
    version = required(opts, :version)
    tag = required(opts, :tag)
    sha = required(opts, :upstream_sha)
    out = required(opts, :out)

    channel = channel_for!(root, version)
    base = opts[:artifact_base] || System.get_env("MISEMACS_ARTIFACT_BASE") || "djgoku/misemacs"

    ref = ref_for!(root, version)

    [mise_toml, pixi_toml, pixi_lock] =
      version
      |> Manifest.version_input_files()
      |> Enum.map(&File.read!(Path.join(root, &1)))

    clt = opts[:clt_fingerprint] || Orchestrator.Toolchain.Macos.clt_fingerprint()

    inputs_hash =
      Hash.version_fingerprint(%{
        toolchain_hash:
          Hash.toolchain_hash(
            File.read!(Path.join(root, "mise.toml")),
            File.read!(Path.join(root, "mise.lock")),
            clt
          ),
        upstream_sha: sha,
        mise_toml: mise_toml,
        pixi_toml: pixi_toml,
        pixi_lock: pixi_lock
      })

    manifest = %{
      "schema" => 1,
      "channel" => channel,
      "repo" => Naming.artifact_repo(base, channel),
      "versions" => %{
        version => %{
          "ref" => ref,
          "upstream_sha" => sha,
          "inputs_hash" => inputs_hash,
          "released_tag" => tag
        }
      }
    }

    File.write!(out, JSON.encode!(manifest) <> "\n")
    IO.puts("wrote #{out}")
  end

  defp ref_for!(root, version) do
    # Toml.decode/1 (non-bang) is the form Manifest.load already uses — proven API.
    with {:ok, map} <- Toml.decode(File.read!(Path.join(root, "versions.toml"))),
         %{"ref" => ref} <- get_in(map, ["versions", version]) do
      ref
    else
      _ -> Mix.raise("no such version #{inspect(version)} in versions.toml")
    end
  end

  defp channel_for!(root, version) do
    with {:ok, map} <- Toml.decode(File.read!(Path.join(root, "versions.toml"))),
         %{"channel" => channel} <- get_in(map, ["versions", version]) do
      channel
    else
      _ -> Mix.raise("no such version #{inspect(version)} (missing channel) in versions.toml")
    end
  end

  defp required(opts, key) do
    opts[key] ||
      Mix.raise("missing required --#{key |> Atom.to_string() |> String.replace("_", "-")}")
  end
end
