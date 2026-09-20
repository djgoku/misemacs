defmodule Orchestrator.PackslipContractTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Naming

  @workflow Path.expand("../../../templates/artifact-packslip.yml", __DIR__)

  test "artifact repository signs published archives under its own identity" do
    workflow = File.read!(@workflow)
    assert workflow =~ "types: [published]"
    assert workflow =~ "uses: jdx/packslip@v1.2.0"
    assert workflow =~ "download: 'misemacs-*.tar.gz'"
    assert workflow =~ "attest: 'false'"
    assert workflow =~ "id-token: write"
  end

  test "packslip executable declarations match the packaged app" do
    workflow = File.read!(@workflow)

    assert workflow =~ "emacs=misemacs/Emacs.app/Contents/MacOS/bin/emacs-cli"
    assert workflow =~ "Emacs=misemacs/Emacs.app/Contents/MacOS/bin/emacs-cli"

    for path <- Naming.bundle_binaries() do
      assert workflow =~ "=misemacs/#{path}", "missing Packslip executable #{path}"
    end
  end
end
