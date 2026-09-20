defmodule Orchestrator.EmacsAppLauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../../pipeline/emacs-app", __DIR__)

  test "launches the enclosing app when invoked through a mise bin symlink" do
    root = Path.join(System.tmp_dir!(), "emacs-app-#{System.unique_integer([:positive])}")
    app = Path.join(root, "misemacs/Emacs.app")
    launcher = Path.join(app, "Contents/MacOS/bin/emacs-app")
    shim = Path.join(root, ".mise-bins/emacs-app")
    fake_open = Path.join(root, "fake-bin/open")
    args_file = Path.join(root, "open-args")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.dirname(launcher))
    File.mkdir_p!(Path.dirname(shim))
    File.mkdir_p!(Path.dirname(fake_open))
    File.cp!(@launcher, launcher)
    File.chmod!(launcher, 0o755)
    File.ln_s!(launcher, shim)
    File.write!(fake_open, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$OPEN_ARGS_FILE\"\n")
    File.chmod!(fake_open, 0o755)

    env = [
      {"PATH", Path.dirname(fake_open) <> ":" <> System.get_env("PATH", "")},
      {"OPEN_ARGS_FILE", args_file}
    ]

    assert {"", 0} = System.cmd(shim, ["--debug-init"], env: env)
    assert File.read!(args_file) == "-n\n#{app}\n--args\n--debug-init\n"

    assert {"", 0} = System.cmd(shim, [], env: env)
    assert File.read!(args_file) == "#{app}\n"
  end
end
