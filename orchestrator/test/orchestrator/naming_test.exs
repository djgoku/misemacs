defmodule Orchestrator.NamingTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @tag_str "v2026.6.0"

  test "tag_base builds a Packslip-discoverable CalVer" do
    assert Naming.tag_base("master", "2026-06-05") == "v2026.6.0"
  end

  test "asset_name uses the release tag and target platform" do
    assert Naming.asset_name(@tag_str, "macos", "arm64") ==
             "misemacs-v2026.6.0-macos-arm64.tar.gz"
  end

  test "asset_name satisfies the archive filename shape" do
    name = Naming.asset_name(@tag_str, "macos", "arm64")
    assert Regex.match?(~r/^misemacs-.+-macos-arm64\.tar\.gz$/, name)
  end

  test "arch token passes through verbatim" do
    assert Naming.asset_name(@tag_str, "macos", "arm64") =~ "-arm64.tar.gz"
    assert Naming.asset_name(@tag_str, "macos", "aarch64") =~ "-aarch64.tar.gz"
  end

  test "asset_stem is the asset name without .tar.gz" do
    name = Naming.asset_name(@tag_str, "macos", "arm64")
    stem = Naming.asset_stem(@tag_str, "macos", "arm64")
    assert name == stem <> ".tar.gz"
  end

  test "inner_dir is the stable tarball top dir, never colliding with a stem" do
    assert Naming.inner_dir() == "misemacs"
    # Asset names retain the channel and version while the archive root stays stable.
    stem = Naming.asset_stem(@tag_str, "macos", "arm64")
    assert String.starts_with?(stem, Naming.inner_dir() <> "-")
    refute stem == Naming.inner_dir()
  end

  test "checksums filename is SHASUMS256.txt" do
    assert Naming.checksums_filename() == "SHASUMS256.txt"
  end

  test "bundle binaries match Packslip's expected extract paths" do
    bins = Naming.bundle_binaries()
    assert "Emacs.app/Contents/MacOS/bin/emacs-cli" in bins
    assert "Emacs.app/Contents/MacOS/bin/emacsclient" in bins
    assert "Emacs.app/Contents/MacOS/bin/etags" in bins
    assert "Emacs.app/Contents/MacOS/bin/ebrowse" in bins
    # The open(1) launcher is embedded by build-emacs [3.5].
    assert "Emacs.app/Contents/MacOS/bin/emacs-app" in bins
  end

  test "bundle_binaries includes the enchant CLIs under Resources/enchant/bin" do
    bins = Naming.bundle_binaries()
    assert "Emacs.app/Contents/Resources/enchant/bin/enchant-2" in bins
    assert "Emacs.app/Contents/Resources/enchant/bin/enchant-lsmod-2" in bins
  end

  test "artifact_repo composes <base>-emacs-<channel>" do
    assert Naming.artifact_repo("djgoku/misemacs", "master") == "djgoku/misemacs-emacs-master"
    assert Naming.artifact_repo("djgoku/misemacs", "31") == "djgoku/misemacs-emacs-31"
  end

  test "artifact_repo honors a custom base (lab)" do
    assert Naming.artifact_repo("djgoku/misemacs-lab", "master") ==
             "djgoku/misemacs-lab-emacs-master"
  end

  # Env precedence (MISEMACS_ARTIFACT_BASE incl. blank-safety) is covered end-to-end by
  # release_manifest_test's blank-env regression; this test pins the pure override path
  # (async-safe: no env mutation here).
  test "artifact_base: override wins; nil falls back to the default base" do
    assert Naming.artifact_base("o/r") == "o/r"
    assert Naming.artifact_base(nil) == "djgoku/misemacs"
    assert Naming.artifact_base() == "djgoku/misemacs"
  end

  test "upstream: per-version override wins; nil falls back to the shared default" do
    assert Naming.upstream("https://example.test/fork/emacs") ==
             "https://example.test/fork/emacs"

    # Env-set (mise [env]) and built-in fallback are the same value by design.
    assert Naming.upstream(nil) == "https://github.com/emacsmirror/emacs"
    assert Naming.upstream() == "https://github.com/emacsmirror/emacs"
  end
end
