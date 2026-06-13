defmodule Orchestrator.NamingTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @tag_str "emacs-master-2026-06-05"

  test "tag_base builds emacs-<channel>-<date>" do
    assert Naming.tag_base("master", "2026-06-05") == "emacs-master-2026-06-05"
  end

  test "asset_name matches the aqua template misemacs-<version>-<os>-<arch>.tar.gz" do
    assert Naming.asset_name(@tag_str, "macos", "arm64") ==
             "misemacs-emacs-master-2026-06-05-macos-arm64.tar.gz"
  end

  test "asset_name satisfies the aqua template shape" do
    name = Naming.asset_name(@tag_str, "macos", "arm64")
    assert Regex.match?(~r/^misemacs-.+-macos-arm64\.tar\.gz$/, name)
  end

  test "arch token passes through verbatim (the registry has NO arch replacement)" do
    # Validated Phase 4 (P7): aqua's {{.Arch}} on darwin/arm64 IS "arm64" (real install).
    # This stays as the canary in case aqua ever changes its normalization.
    assert Naming.asset_name(@tag_str, "macos", "arm64") =~ "-arm64.tar.gz"
    assert Naming.asset_name(@tag_str, "macos", "aarch64") =~ "-aarch64.tar.gz"
  end

  test "asset_stem is the asset name without .tar.gz (the tarball top dir)" do
    name = Naming.asset_name(@tag_str, "macos", "arm64")
    stem = Naming.asset_stem(@tag_str, "macos", "arm64")
    assert name == stem <> ".tar.gz"
  end

  test "checksums filename is SHASUMS256.txt" do
    assert Naming.checksums_filename() == "SHASUMS256.txt"
  end

  test "bundle binaries match the registry's expected extract paths" do
    bins = Naming.bundle_binaries()
    assert "Emacs.app/Contents/MacOS/Emacs" in bins
    assert "Emacs.app/Contents/MacOS/bin/emacsclient" in bins
    assert "Emacs.app/Contents/MacOS/bin/etags" in bins
    assert "Emacs.app/Contents/MacOS/bin/ebrowse" in bins
  end
end
