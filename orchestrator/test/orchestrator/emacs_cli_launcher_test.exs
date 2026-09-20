defmodule Orchestrator.EmacsCliLauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../../pipeline/emacs-cli", __DIR__)

  test "runs the bundled Emacs by its app path through a mise bin symlink" do
    root = Path.join(System.tmp_dir!(), "emacs-cli-#{System.unique_integer([:positive])}")
    app = Path.join(root, "Emacs.app")
    launcher = Path.join(app, "Contents/MacOS/bin/emacs-cli")
    executable = Path.join(app, "Contents/MacOS/Emacs")
    shim = Path.join(root, ".mise-bins/Emacs")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.dirname(launcher))
    File.mkdir_p!(Path.dirname(shim))
    File.cp!(@launcher, launcher)
    File.chmod!(launcher, 0o755)
    File.ln_s!(launcher, shim)
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\"\n")
    File.chmod!(executable, 0o755)

    assert {output, 0} = System.cmd(shim, ["--batch", "--eval", "(princ 1)"])
    assert output == "#{executable}\n--batch\n--eval\n(princ 1)\n"
  end
end
