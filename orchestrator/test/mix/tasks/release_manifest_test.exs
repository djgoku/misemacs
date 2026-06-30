defmodule Mix.Tasks.Release.ManifestTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Orchestrator.Core.Hash

  setup do
    root = Path.join(System.tmp_dir!(), "manifest-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "versions/master"))
    File.write!(Path.join(root, "mise.toml"), "# repo mise.toml\n")
    File.write!(Path.join(root, "mise.lock"), "# repo mise.lock\n")

    File.write!(Path.join(root, "versions.toml"), """
    [versions.master]
    ref = "master"
    channel = "master"
    """)

    File.write!(Path.join(root, "versions/master/mise.toml"), "# v mise\n")
    File.write!(Path.join(root, "versions/master/pixi.toml"), "# v pixi\n")
    File.write!(Path.join(root, "versions/master/pixi.lock"), "# v lock\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, out: Path.join(root, "build-manifest.json")}
  end

  defp run(root, out, extra \\ []) do
    args =
      [
        "--root",
        root,
        "--out",
        out,
        "--version",
        "master",
        "--tag",
        "emacs-master-2026-06-11",
        "--upstream-sha",
        "abc123"
      ] ++ ["--clt-fingerprint", "clt-fixture"] ++ extra

    capture_io(fn -> Mix.Task.rerun("release.manifest", args) end)
  end

  test "writes the schema-1 manifest with the Core.Hash fingerprint", %{root: root, out: out} do
    run(root, out)
    manifest = out |> File.read!() |> JSON.decode!()

    assert manifest["schema"] == 1
    entry = manifest["versions"]["master"]
    assert entry["ref"] == "master"
    assert entry["released_tag"] == "emacs-master-2026-06-11"
    assert entry["upstream_sha"] == "abc123"

    expected =
      Hash.version_fingerprint(%{
        toolchain_hash:
          Hash.toolchain_hash("# repo mise.toml\n", "# repo mise.lock\n", "clt-fixture"),
        upstream_sha: "abc123",
        mise_toml: "# v mise\n",
        pixi_toml: "# v pixi\n",
        pixi_lock: "# v lock\n"
      })

    assert entry["inputs_hash"] == expected
  end

  test "fails loudly for a version missing from versions.toml", %{root: root, out: out} do
    assert_raise Mix.Error, ~r/no such version/, fn ->
      capture_io(fn ->
        Mix.Task.rerun("release.manifest", [
          "--root",
          root,
          "--out",
          out,
          "--version",
          "nope",
          "--tag",
          "t",
          "--upstream-sha",
          "abc"
        ])
      end)
    end
  end

  test "fails loudly on a missing input file", %{root: root, out: out} do
    File.rm!(Path.join(root, "versions/master/pixi.lock"))
    assert_raise File.Error, fn -> run(root, out) end
  end

  test "blank MISEMACS_ARTIFACT_BASE falls back to default (not '-emacs-master')", %{
    root: root,
    out: out
  } do
    System.put_env("MISEMACS_ARTIFACT_BASE", "")

    on_exit(fn -> System.delete_env("MISEMACS_ARTIFACT_BASE") end)

    run(root, out)
    manifest = out |> File.read!() |> JSON.decode!()
    assert manifest["repo"] == "djgoku/misemacs-emacs-master"
  end

  test "fragment stamps channel (from versions.toml) and artifact repo at top level" do
    dir = Path.join(System.tmp_dir!(), "frag-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    out = Path.join(dir, "build-manifest.json")

    Mix.Tasks.Release.Manifest.run([
      "--version", "master",
      "--tag", "emacs-master-2026-06-29",
      "--upstream-sha", "deadbeef",
      "--out", out,
      "--root", "..",
      "--clt-fingerprint", "test-clt"
    ])

    m = out |> File.read!() |> JSON.decode!()
    assert m["channel"] == "master"
    assert m["repo"] == "djgoku/misemacs-emacs-master"
    assert m["versions"]["master"]["released_tag"] == "emacs-master-2026-06-29"
  end
end
