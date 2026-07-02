defmodule Mix.Tasks.Release.ArtifactReadmeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  @registry "MISE_AQUA_REGISTRIES=https://raw.githubusercontent.com/djgoku/misemacs/main/aqua/registry.yaml"

  defp gen(version),
    do:
      capture_io(fn ->
        Mix.Tasks.Release.ArtifactReadme.run(["--version", version, "--root", ".."])
      end)

  test "master README: repo, channel, ref, and all three install methods" do
    out = gen("master")
    assert out =~ "djgoku/misemacs-emacs-master"
    assert out =~ "=master= channel"
    assert out =~ "=master= ref"
    assert out =~ "mise use aqua:djgoku/misemacs-emacs-master@latest"
    assert out =~ @registry
    assert out =~ "mise use github:djgoku/misemacs-emacs-master@latest"
  end

  test "emacs-31 README: channel \"31\", ref \"emacs-31\", repo, and all three install methods" do
    out = gen("emacs-31")
    assert out =~ "djgoku/misemacs-emacs-31"
    assert out =~ "=31= channel"
    assert out =~ "=emacs-31= ref"
    assert out =~ "emacs-31-YYYY-MM-DD"
    assert out =~ "mise use aqua:djgoku/misemacs-emacs-31@latest"
    assert out =~ @registry
    assert out =~ "mise use github:djgoku/misemacs-emacs-31@latest"
  end

  test "README documents the 3 release assets + verification + source pointer" do
    out = gen("master")
    assert out =~ "build-manifest.json"
    assert out =~ "SHASUMS256.txt"
    assert out =~ "macos-arm64.tar.gz"
    assert out =~ "shasum -c"
    assert out =~ "do not open issues or pull requests here"
  end

  test "README is version-agnostic — contains NO literal date" do
    refute gen("master") =~ ~r/\d{4}-\d{2}-\d{2}/
  end

  test "unknown version raises loudly" do
    assert_raise Mix.Error, ~r/no such version/, fn ->
      capture_io(fn ->
        Mix.Tasks.Release.ArtifactReadme.run(["--version", "nope", "--root", ".."])
      end)
    end
  end
end
