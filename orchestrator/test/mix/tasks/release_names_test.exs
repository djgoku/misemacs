defmodule Mix.Tasks.Release.NamesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @base_args ~w(--os macos --arch arm64)

  defp run(args) do
    capture_io(fn -> Mix.Task.rerun("release.names", args) end)
  end

  defp kv(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "="))
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.reduce(%{}, fn [k, v], acc ->
      Map.update(acc, k, [v], &(&1 ++ [v]))
    end)
  end

  test "given-tag mode emits names for the explicit tag, no snapshot needed" do
    out = kv(run(["--tag", "emacs-master-2026-06-11" | @base_args]))
    assert out["tag"] == ["emacs-master-2026-06-11"]
    assert out["asset"] == ["misemacs-emacs-master-2026-06-11-macos-arm64.tar.gz"]
    assert out["stem"] == ["misemacs-emacs-master-2026-06-11-macos-arm64"]
    assert out["checksums"] == ["SHASUMS256.txt"]
  end

  test "given-tag mode works for arbitrary sentinel tags (pregate)" do
    out = kv(run(["--tag", "pregate-smoke" | @base_args]))
    assert out["asset"] == ["misemacs-pregate-smoke-macos-arm64.tar.gz"]
  end

  test "bin= lines are exactly Naming.bundle_binaries/0 in order" do
    out = kv(run(["--tag", "t" | @base_args]))
    assert out["bin"] == Orchestrator.Naming.bundle_binaries()
  end

  test "snapshot mode computes the tag via Core.Tag (no collision)" do
    tags = write_tags(["emacs-master-2026-06-10"])

    out =
      kv(run(["--channel", "master", "--date", "2026-06-11", "--tags-file", tags | @base_args]))

    assert out["tag"] == ["emacs-master-2026-06-11"]
  end

  test "snapshot mode appends .N on same-day collision" do
    tags = write_tags(["emacs-master-2026-06-11", "emacs-master-2026-06-11.1"])

    out =
      kv(run(["--channel", "master", "--date", "2026-06-11", "--tags-file", tags | @base_args]))

    assert out["tag"] == ["emacs-master-2026-06-11.2"]
    assert out["asset"] == ["misemacs-emacs-master-2026-06-11.2-macos-arm64.tar.gz"]
  end

  test "snapshot mode reads the snapshot from stdin with --tags-file -" do
    out =
      capture_io("emacs-master-2026-06-11\n", fn ->
        Mix.Task.rerun(
          "release.names",
          ["--channel", "master", "--date", "2026-06-11", "--tags-file", "-" | @base_args]
        )
      end)

    assert kv(out)["tag"] == ["emacs-master-2026-06-11.1"]
  end

  test "raises without --os/--arch" do
    assert_raise Mix.Error, fn -> run(["--tag", "t", "--os", "macos"]) end
  end

  test "raises when neither --tag nor --channel mode is complete" do
    assert_raise Mix.Error, fn -> run(@base_args) end
    assert_raise Mix.Error, fn -> run(["--channel", "master" | @base_args]) end
  end

  defp write_tags(tags) do
    path = Path.join(System.tmp_dir!(), "tags-#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.join(tags, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
