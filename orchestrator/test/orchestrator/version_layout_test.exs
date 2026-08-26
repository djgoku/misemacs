defmodule Orchestrator.VersionLayoutTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Manifest

  @repo_root Path.expand("../../..", __DIR__)

  test "version_input_files/1 lists the three per-version build inputs (relative to repo root)" do
    assert Manifest.version_input_files("master") == [
             "versions/master/mise.toml",
             "versions/master/pixi.toml",
             "versions/master/pixi.lock"
           ]
  end

  test "every versions.toml entry has its versions/<name>/ build inputs committed on disk" do
    {:ok, vbin} = File.read(Path.join(@repo_root, "versions.toml"))
    {:ok, vmap} = Toml.decode(vbin)
    names = Map.keys(Map.get(vmap, "versions", %{}))

    assert names != [], "versions.toml has no [versions.*] entries"
    assert Manifest.missing_version_files(@repo_root, names) == []
  end

  test "emacs-30 stays on the pre-0.26 tree-sitter ABI it builds against" do
    version_dir = Path.join([@repo_root, "versions", "emacs-30"])
    {:ok, pixi_toml} = File.read(Path.join(version_dir, "pixi.toml"))
    {:ok, pixi_config} = Toml.decode(pixi_toml)
    {:ok, pixi_lock} = File.read(Path.join(version_dir, "pixi.lock"))

    assert get_in(pixi_config, ["dependencies", "libtree-sitter"]) == ">=0.25,<0.26"
    assert pixi_lock =~ ~r/libtree-sitter-0\.25\.\d+-/
    refute pixi_lock =~ ~r/libtree-sitter-0\.26\.\d+-/
  end
end
