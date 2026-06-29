defmodule Mix.Tasks.Orchestrate.DecideTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Orchestrator.Core.Hash

  @fixtures Path.expand("../../support/fixtures", __DIR__)

  # Tmp root for detect-mode tests: fixture versions/targets plus known input-file
  # bytes for both fixture versions (master, emacs-30.2).
  defp tmp_detect_root do
    root = Path.join(System.tmp_dir!(), "decide-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "mise.toml"), "# repo\n")
    File.write!(Path.join(root, "mise.lock"), "# lock\n")
    File.cp!(Path.join(@fixtures, "versions.toml"), Path.join(root, "versions.toml"))
    File.cp!(Path.join(@fixtures, "targets.toml"), Path.join(root, "targets.toml"))

    for v <- ~w(master emacs-30.2) do
      File.mkdir_p!(Path.join(root, "versions/#{v}"))

      for f <- ~w(mise.toml pixi.toml pixi.lock),
          do: File.write!(Path.join(root, "versions/#{v}/#{f}"), "# #{f}\n")
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "dry-run mode emits matrix + any + dry_run (no IO, reads fixtures)" do
    out =
      capture_io(fn ->
        Mix.Task.rerun("orchestrate.decide", [
          "--mode",
          "dry-run",
          "--date",
          "2026-06-13",
          "--root",
          @fixtures
        ])
      end)

    assert out =~ ~r/^matrix=\{"include":\[/m
    assert out =~ "any=true"
    assert out =~ "dry_run=true"
  end

  test "force mode emits only the forced version" do
    out =
      capture_io(fn ->
        Mix.Task.rerun("orchestrate.decide", [
          "--mode",
          "force",
          "--force-version",
          "master",
          "--date",
          "2026-06-13",
          "--root",
          @fixtures
        ])
      end)

    assert out =~ ~s("name":"master")
    refute out =~ ~s("name":"emacs-30.2")
    assert out =~ "dry_run=false"
  end

  test "detect mode wires injected deps (no network) over a tmp root" do
    root = tmp_detect_root()

    deps = %{
      upstream: fn _ref -> "sha-x" end,
      releases: fn _repo -> :empty end,
      toolchain: fn -> "sha256:cltfix" end
    }

    out =
      Mix.Tasks.Orchestrate.Decide.exec(
        %{mode: "detect", date: "2026-06-13", repo: "o/r", root: root},
        deps
      )

    assert out.any == true
    assert out.dry_run == false
    assert Enum.any?(out.matrix["include"], &(&1.name == "master"))
  end

  test "detect: :error from a channel repo aborts the run" do
    deps = %{
      upstream: fn _v -> "sha" end,
      toolchain: fn -> "test-clt" end,
      releases: fn
        "djgoku/misemacs-emacs-31" -> {:error, :unauthorized}
        "djgoku/misemacs-emacs-master" -> :empty
        other -> flunk("unexpected repo #{other}")
      end
    }

    assert_raise Mix.Error, ~r/unauthorized/, fn ->
      Mix.Tasks.Orchestrate.Decide.exec(
        %{repo: "djgoku/misemacs", date: "2026-06-29", mode: "detect", root: ".."},
        deps
      )
    end
  end

  test "detect: {:ok, manifest} with matching state suppresses that version, others build" do
    root = tmp_detect_root()

    # Recompute exactly what current_states/4 will fingerprint for master over this root,
    # so the "prior" manifest matches and master is suppressed as :unchanged.
    toolchain_hash = Hash.toolchain_hash("# repo\n", "# lock\n", "sha256:cltfix")

    inputs_hash =
      Hash.version_fingerprint(%{
        toolchain_hash: toolchain_hash,
        upstream_sha: "sha-x",
        mise_toml: "# mise.toml\n",
        pixi_toml: "# pixi.toml\n",
        pixi_lock: "# pixi.lock\n"
      })

    manifest = %{
      "schema" => 1,
      "versions" => %{"master" => %{"upstream_sha" => "sha-x", "inputs_hash" => inputs_hash}}
    }

    deps = %{
      upstream: fn _ref -> "sha-x" end,
      toolchain: fn -> "sha256:cltfix" end,
      releases: fn
        "o/r-emacs-master" -> {:ok, manifest}
        "o/r-emacs-30.2" -> :empty
        other -> flunk("unexpected repo #{other}")
      end
    }

    out =
      Mix.Tasks.Orchestrate.Decide.exec(
        %{mode: "detect", date: "2026-06-13", repo: "o/r", root: root},
        deps
      )

    names = Enum.map(out.matrix["include"], & &1.name)
    assert "emacs-30.2" in names
    refute "master" in names
    assert out.any == true
  end

  test "detect: all channels :empty => every version is first-run (builds)" do
    deps = %{
      upstream: fn _v -> "newsha" end,
      toolchain: fn -> "test-clt" end,
      releases: fn _repo -> :empty end
    }

    out =
      Mix.Tasks.Orchestrate.Decide.exec(
        %{repo: "djgoku/misemacs", date: "2026-06-29", mode: "detect", root: ".."},
        deps
      )

    assert out.any == true
  end
end
