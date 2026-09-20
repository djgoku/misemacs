defmodule Orchestrator.Naming do
  @moduledoc """
  SOLE owner of release tag / asset / checksum name strings.

  The release tag is a Packslip-discoverable SemVer CalVer. The archive keeps its
  existing macos-arm64 filename and stable `misemacs/` top-level directory.
  """

  @asset_prefix "misemacs"
  @inner_dir "misemacs"
  @format "tar.gz"
  @checksums "SHASUMS256.txt"
  @default_base "djgoku/misemacs"

  @doc """
  Artifact-repo base: `override || env || "djgoku/misemacs"`. `override` is the caller's
  explicit candidate (its CLI opt); env is `MISEMACS_ARTIFACT_BASE` via `env_artifact_base/0`.
  Callers with env-first precedence (decide) compose explicitly.
  """
  @spec artifact_base(String.t() | nil) :: String.t()
  def artifact_base(override \\ nil), do: override || env_artifact_base() || @default_base

  @doc "Blank-safe `MISEMACS_ARTIFACT_BASE`: nil when unset OR blank (mirrors bash `${VAR:-default}`)."
  @spec env_artifact_base() :: String.t() | nil
  def env_artifact_base do
    case System.get_env("MISEMACS_ARTIFACT_BASE") do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  @default_upstream "https://github.com/emacsmirror/emacs"

  @doc """
  Upstream Emacs repo URL: `override || env || default`. `override` is a version's optional
  `upstream` key from versions.toml (per-version fork, e.g. a future emacs-mac channel);
  env is `EMACS_UPSTREAM` (root mise.toml `[env]`, which the fallback matches).
  """
  @spec upstream(String.t() | nil) :: String.t()
  def upstream(override \\ nil),
    do: override || System.get_env("EMACS_UPSTREAM") || @default_upstream

  @doc "First release tag for a month. Repos isolate channels; the counter starts at zero."
  @spec tag_base(String.t(), String.t()) :: String.t()
  def tag_base(_channel, date) do
    {:ok, parsed} = Date.from_iso8601(date)
    "v#{parsed.year}.#{parsed.month}.0"
  end

  @doc "Packslip's SemVer version for a release tag."
  @spec packslip_version(String.t()) :: String.t()
  def packslip_version("v" <> version) do
    {:ok, _} = Version.parse(version)
    version
  end

  @doc """
  Artifact repo for a channel: `<base>-emacs-<channel>` (e.g.
  `djgoku/misemacs-emacs-master`). `base` is the source-repo-shaped prefix; the lab
  passes its own (`djgoku/misemacs-lab`). SOLE owner of the channel→repo convention.
  """
  @spec artifact_repo(String.t(), String.t()) :: String.t()
  def artifact_repo(base, channel), do: "#{base}-emacs-#{channel}"

  @doc "Release asset filename for a tag/os/arch."
  @spec asset_name(String.t(), String.t(), String.t()) :: String.t()
  def asset_name(tag, os, arch), do: "#{asset_stem(tag, os, arch)}.#{@format}"

  @doc """
  Asset name without the .tar.gz extension. The archive's real top-level dir is
  `inner_dir/0`.
  """
  @spec asset_stem(String.t(), String.t(), String.t()) :: String.t()
  def asset_stem(tag, os, arch), do: "#{@asset_prefix}-#{tag}-#{os}-#{arch}"

  @doc """
  STABLE top-level dir inside the tarball (constant across releases and channels), so
  `installs/<tool>/latest/#{@inner_dir}/Emacs.app` never moves and a one-time
  `ln -sfn` into ~/Applications survives `mise up` (README "Open it like an app").

  Packslip declares executable paths under this directory directly.
  """
  @spec inner_dir() :: String.t()
  def inner_dir, do: @inner_dir

  @doc "Checksums asset filename attached to every release."
  @spec checksums_filename() :: String.t()
  def checksums_filename, do: @checksums

  @doc "Executable paths relative to the stable archive root, declared in Packslip."
  @spec bundle_binaries() :: [String.t()]
  def bundle_binaries do
    [
      "Emacs.app/Contents/MacOS/bin/emacs-cli",
      "Emacs.app/Contents/MacOS/bin/emacsclient",
      "Emacs.app/Contents/MacOS/bin/etags",
      "Emacs.app/Contents/MacOS/bin/ebrowse",
      # open(1) launcher embedded by pipeline/build-emacs [3.5]; absent in releases
      # before 2026-08-09 — mise skips missing files srcs (probed, mise 2026.8.3).
      "Emacs.app/Contents/MacOS/bin/emacs-app",
      "Emacs.app/Contents/Resources/enchant/bin/enchant-2",
      "Emacs.app/Contents/Resources/enchant/bin/enchant-lsmod-2"
    ]
  end
end
