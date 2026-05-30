ExUnit.start()
Code.require_file("../cli/misemacs_lib.exs", __DIR__)

defmodule Misemacs.InputsHashTest do
  use ExUnit.Case, async: true
  alias Misemacs.Lib

  defp write!(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp fixture!(root) do
    write!(root, "pkgs/emacs-master/lockfile.toml", "sha = \"abc\"\n")
    write!(root, "pkgs/emacs-master/build.toml", "configure = \"--with-x\"\n")
    write!(root, "libs/enchant/lockfile.toml", "sha = \"def\"\n")
    write!(root, "libs/enchant/build.toml", "rule = \"autotools\"\n")
    write!(root, "mise.lock", "[tools]\n")
    write!(root, "scripts/build/foo.sh", "echo hi\n")
    root
  end

  @tag :tmp_dir
  test "deterministic and lowercase-64-hex", %{tmp_dir: root} do
    fixture!(root)
    h1 = Lib.inputs_hash(root, "emacs-master")
    h2 = Lib.inputs_hash(root, "emacs-master")
    assert h1 == h2
    assert h1 =~ ~r/^[0-9a-f]{64}$/
  end

  @tag :tmp_dir
  test "changes when any input byte changes", %{tmp_dir: root} do
    fixture!(root)
    h1 = Lib.inputs_hash(root, "emacs-master")
    File.write!(Path.join(root, "mise.lock"), "[tools]\nbumped\n")
    refute h1 == Lib.inputs_hash(root, "emacs-master")
  end

  @tag :tmp_dir
  test "raises on unknown flavor", %{tmp_dir: root} do
    fixture!(root)
    assert_raise RuntimeError, fn -> Lib.inputs_hash(root, "nope") end
  end

  @tag :tmp_dir
  test "raises on a missing input file (no silent partial hash)", %{tmp_dir: root} do
    fixture!(root)
    File.rm!(Path.join(root, "mise.lock"))
    assert_raise File.Error, fn -> Lib.inputs_hash(root, "emacs-master") end
  end
end
