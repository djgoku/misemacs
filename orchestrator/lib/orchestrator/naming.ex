defmodule Orchestrator.Naming do
  @moduledoc """
  SOLE owner of release tag / asset / checksum name strings.

  These MUST match the consumed aqua registry template — the vendored
  `aqua/registry.yaml` in this repo, bound here by `registry_contract_test.exs`
  (Phase 4, P7/G5; the `djgoku/aqua-registry@feat/...` branch is a PR-shaped copy,
  not the file `MISE_AQUA_REGISTRY_URL` serves):

      misemacs-{{.Version}}-{{.OS}}-{{.Arch}}.tar.gz   (darwin -> macos, format tar.gz)

  where {{.Version}} is the git tag. Any drift here silently breaks `mise use aqua:...`.

  ARCH NOTE: the registry has NO arch replacement, so the `arch` passed in MUST equal the
  token aqua renders for the platform ({{.Arch}}). VALIDATED (Phase 4, P7): a real
  `mise install` resolved `…-macos-arm64.tar.gz` on darwin/arm64 — aqua renders `arm64`.
  """

  @asset_prefix "misemacs"
  @format "tar.gz"
  @checksums "SHASUMS256.txt"

  @doc "Base release tag for a channel/date: `emacs-<channel>-<date>` (no `.N` suffix)."
  @spec tag_base(String.t(), String.t()) :: String.t()
  def tag_base(channel, date), do: "emacs-#{channel}-#{date}"

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

  @doc "Top-level dir inside the tarball == asset name without the .tar.gz extension."
  @spec asset_stem(String.t(), String.t(), String.t()) :: String.t()
  def asset_stem(tag, os, arch), do: "#{@asset_prefix}-#{tag}-#{os}-#{arch}"

  @doc "Checksums asset filename attached to every release."
  @spec checksums_filename() :: String.t()
  def checksums_filename, do: @checksums

  @doc "Paths (relative to the stem dir) that aqua extracts onto PATH."
  @spec bundle_binaries() :: [String.t()]
  def bundle_binaries do
    [
      "Emacs.app/Contents/MacOS/Emacs",
      "Emacs.app/Contents/MacOS/bin/emacsclient",
      "Emacs.app/Contents/MacOS/bin/etags",
      "Emacs.app/Contents/MacOS/bin/ebrowse",
      "Emacs.app/Contents/Resources/enchant/bin/enchant-2",
      "Emacs.app/Contents/Resources/enchant/bin/enchant-lsmod-2"
    ]
  end
end
