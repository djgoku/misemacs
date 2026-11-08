defmodule Orchestrator.BuildDirTest do
  use ExUnit.Case, async: true
  alias Orchestrator.BuildDir

  @moduletag :tmp_dir

  test "loads the app path and conda lib dir, trimming the file's newline", %{tmp_dir: root} do
    dir = Path.join([root, "build", "emacs-31"])
    File.mkdir_p!(Path.join(dir, "Emacs.app"))
    File.write!(Path.join(dir, "conda-prefix-lib.txt"), "/env/default/lib\n")

    assert {:ok, build} = BuildDir.load(root, "emacs-31")
    assert build.app == Path.join(dir, "Emacs.app")
    assert build.conda_lib == "/env/default/lib"
    assert BuildDir.conda_prefix(build) == "/env/default"
  end

  test "names the missing app and the build command", %{tmp_dir: root} do
    assert {:error, msg} = BuildDir.load(root, "master")
    assert msg =~ "build/master/Emacs.app missing"
    assert msg =~ "mise run build master"
  end

  test "names the missing conda-prefix-lib.txt", %{tmp_dir: root} do
    File.mkdir_p!(Path.join([root, "build", "master", "Emacs.app"]))
    assert {:error, msg} = BuildDir.load(root, "master")
    assert msg =~ "conda-prefix-lib.txt missing"
  end

  test "relocate and payload.enchant default to master under the parent root" do
    assert Mix.Tasks.Relocate.parse([]) == {"..", "master"}
    assert Mix.Tasks.Relocate.parse(["emacs-30", "--root", "/r"]) == {"/r", "emacs-30"}
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Relocate.parse(["a", "b"]) end
  end
end
