defmodule Mix.Tasks.Orchestrate.DecideTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @fixtures Path.expand("../../support/fixtures", __DIR__)

  test "dry-run mode emits matrix + any + dry_run (no IO, reads fixtures)" do
    out =
      capture_io(fn ->
        Mix.Task.rerun("orchestrate.decide", ["--mode", "dry-run", "--date", "2026-06-13", "--root", @fixtures])
      end)

    assert out =~ ~r/^matrix=\{"include":\[/m
    assert out =~ "any=true"
    assert out =~ "dry_run=true"
  end

  test "force mode emits only the forced version" do
    out =
      capture_io(fn ->
        Mix.Task.rerun("orchestrate.decide", ["--mode", "force", "--force-version", "master", "--date", "2026-06-13", "--root", @fixtures])
      end)

    assert out =~ ~s("name":"master")
    refute out =~ ~s("name":"emacs-30.2")
    assert out =~ "dry_run=false"
  end

  test "detect mode wires injected deps (no network) over a tmp root" do
    root = Path.join(System.tmp_dir!(), "decide-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "versions/master"))
    File.write!(Path.join(root, "mise.toml"), "# repo\n")
    File.write!(Path.join(root, "mise.lock"), "# lock\n")
    File.cp!(Path.join(@fixtures, "versions.toml"), Path.join(root, "versions.toml"))
    File.cp!(Path.join(@fixtures, "targets.toml"), Path.join(root, "targets.toml"))
    for f <- ~w(mise.toml pixi.toml pixi.lock), do: File.write!(Path.join(root, "versions/master/#{f}"), "# #{f}\n")
    # versions.toml fixture also has emacs-30.2; give it input files too
    File.mkdir_p!(Path.join(root, "versions/emacs-30.2"))
    for f <- ~w(mise.toml pixi.toml pixi.lock), do: File.write!(Path.join(root, "versions/emacs-30.2/#{f}"), "# #{f}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    deps = %{
      upstream: fn _ref -> "sha-x" end,
      releases: fn _repo -> nil end,
      toolchain: fn -> "sha256:cltfix" end
    }

    out = Mix.Tasks.Orchestrate.Decide.exec(%{mode: "detect", date: "2026-06-13", repo: "o/r", root: root}, deps)
    assert out.any == true
    assert out.dry_run == false
    assert Enum.any?(out.matrix["include"], &(&1.name == "master"))
  end
end
