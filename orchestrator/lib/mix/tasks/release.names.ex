defmodule Mix.Tasks.Release.Names do
  @shortdoc "Print release tag/asset/stem/checksums/bin names (snapshot or given-tag mode)"
  @moduledoc """
  Sole bash-facing source of release name strings (spec §4.2). Network-free.

      # snapshot mode (publish computes the next tag, .N on collision):
      mix release.names --channel master --date 2026-06-11 --os macos --arch arm64 --tags-file -

      # given-tag mode (package / pregate sentinel — skips Core.Tag):
      mix release.names --tag emacs-master-2026-06-11 --os macos --arch arm64

  Output: `key=value` lines — tag, asset, stem, checksums, then one `bin=` line
  per `Naming.bundle_binaries/0` entry. Bash must parse, never re-derive.
  """
  use Mix.Task
  alias Orchestrator.{Core.Tag, Naming}

  @switches [
    channel: :string,
    date: :string,
    os: :string,
    arch: :string,
    tags_file: :string,
    tag: :string,
    version: :string,
    root: :string
  ]

  @impl true
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    os = required(opts, :os)
    arch = required(opts, :arch)
    validate_version_channel!(opts)
    tag = resolve_tag(opts)

    IO.puts("tag=#{tag}")
    IO.puts("asset=#{Naming.asset_name(tag, os, arch)}")
    IO.puts("stem=#{Naming.asset_stem(tag, os, arch)}")
    IO.puts("checksums=#{Naming.checksums_filename()}")
    Enum.each(Naming.bundle_binaries(), &IO.puts("bin=#{&1}"))
  end

  # When both --version and --channel are supplied, assert the version's channel in
  # versions.toml equals --channel. Guards against a caller passing mismatched args
  # (e.g. --version emacs-31 --channel master), which would tag the wrong release.
  defp validate_version_channel!(opts) do
    with version when is_binary(version) <- opts[:version],
         channel when is_binary(channel) <- opts[:channel] do
      root = opts[:root] || ".."

      actual =
        with {:ok, map} <- Toml.decode(File.read!(Path.join(root, "versions.toml"))),
             %{"channel" => ch} <- get_in(map, ["versions", version]) do
          ch
        else
          _ -> Mix.raise("no such version #{inspect(version)} in versions.toml")
        end

      if actual != channel do
        Mix.raise(
          "version↔channel mismatch: version #{inspect(version)} has channel #{inspect(actual)}" <>
            " in versions.toml, but --channel #{inspect(channel)} was passed"
        )
      end
    end
  end

  defp resolve_tag(opts) do
    case {opts[:tag], opts[:channel]} do
      {tag, nil} when is_binary(tag) ->
        tag

      {nil, channel} when is_binary(channel) ->
        Tag.next_tag(channel, required(opts, :date), read_tags(required(opts, :tags_file)))

      _ ->
        Mix.raise("usage: --tag <tag> | --channel <ch> --date <YYYY-MM-DD> --tags-file <path|->")
    end
  end

  defp read_tags("-") do
    case IO.read(:stdio, :eof) do
      :eof -> []
      data -> split_tags(data)
    end
  end

  defp read_tags(path), do: path |> File.read!() |> split_tags()

  defp split_tags(data), do: data |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

  defp required(opts, key) do
    opts[key] ||
      Mix.raise("missing required --#{key |> Atom.to_string() |> String.replace("_", "-")}")
  end
end
