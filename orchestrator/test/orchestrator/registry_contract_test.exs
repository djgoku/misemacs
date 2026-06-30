defmodule Orchestrator.RegistryContractTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @moduledoc """
  Binds the VENDORED consumer registry (aqua/registry.yaml — what
  MISE_AQUA_REGISTRY_URL serves from this repo's main) to Orchestrator.Naming.
  Line-presence checks on the small, stable YAML — deliberately no YAML dep.
  Drift in either direction must break the suite (spec G5/P7).
  """

  @registry_path Path.expand("../../../aqua/registry.yaml", __DIR__)

  setup_all do
    %{
      registry: File.read!(@registry_path),
      # Naming.asset_name/3 is pure interpolation, so feeding it the aqua
      # placeholders yields the registry template — ONE source binding the
      # file-presence and rendering assertions below (no retyped literal).
      template: Naming.asset_name("{{.Version}}", "{{.OS}}", "{{.Arch}}")
    }
  end

  test "registry file exists at the consumed path" do
    assert File.exists?(@registry_path)
  end

  test "asset template + format + os replacement are present verbatim", %{
    registry: reg,
    template: template
  } do
    assert reg =~ "asset: #{template}"
    assert reg =~ "format: tar.gz"
    assert reg =~ "darwin: macos"
    assert reg =~ "repo_owner: djgoku"
  end

  test "checksum contract matches Naming.checksums_filename/0", %{registry: reg} do
    assert reg =~ "asset: #{Naming.checksums_filename()}"
    assert reg =~ "algorithm: sha256"
    # Scoped to the checksum block: the package-level `type: github_release`
    # line must not satisfy this assertion.
    assert reg =~ ~r/checksum:\s*\n\s*type: github_release/
  end

  test "rendering the registry template == Naming.asset_name/3 (darwin->macos, arm64)", %{
    template: template
  } do
    tag = "emacs-master-2026-06-11"

    rendered =
      template
      |> String.replace("{{.Version}}", tag)
      |> String.replace("{{.OS}}", "macos")
      |> String.replace("{{.Arch}}", "arm64")

    assert rendered == Naming.asset_name(tag, "macos", "arm64")
  end

  test "every Naming.bundle_binaries/0 path appears as a files src entry", %{registry: reg} do
    for bin <- Naming.bundle_binaries() do
      assert reg =~ ~s(src: "{{.AssetWithoutExt}}/#{bin}"),
             "registry is missing files src for #{bin}"
    end

    # One package per channel, each repeating the full src set — count packages by
    # their version_prefix line so the reverse guard scales. (Phase 6: generate the
    # registry from versions.toml; until then this binds the hand-maintained file.)
    n_packages = length(Regex.scan(~r/^\s+version_prefix:/m, reg))

    # Reverse guard: a src entry NOT owned by Naming.bundle_binaries/0 fails too.
    assert length(Regex.scan(~r/src: "/, reg)) == length(Naming.bundle_binaries()) * n_packages
  end

  test "one version_prefix package per channel (name + prefix bound)", %{registry: reg} do
    for channel <- ["master", "31"] do
      assert reg =~ "name: djgoku/misemacs-emacs-#{channel}"
      assert reg =~ ~s(version_prefix: "emacs-#{channel}-")
    end
  end

  test "supported env is darwin/arm64 only", %{registry: reg} do
    [envs_block] =
      Regex.run(~r/supported_envs:\n((?:\s+-\s+\S+\n)+)/, reg, capture: :all_but_first)

    assert Regex.scan(~r/-\s+(\S+)/, envs_block, capture: :all_but_first) == [["darwin/arm64"]]
  end

  test "each package points at its per-channel artifact repo", %{registry: reg} do
    assert reg =~ "repo_name: misemacs-emacs-master"
    assert reg =~ "repo_name: misemacs-emacs-31"
  end

  test "both packages keep version_source: github_tag", %{registry: reg} do
    assert length(Regex.scan(~r/version_source:\s*github_tag/, reg)) == 2
  end
end
