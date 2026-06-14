defmodule Orchestrator.OrchestrateTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Orchestrate

  @versions [%{name: "master", channel: "master", ref: "master"}]
  @jobs [%{name: "master", channel: "master", ref: "master", target: "macos-arm64", os: "macos", arch: "arm64", runner: "macos-26"}]

  test "detect: first run builds, any=true, dry_run=false" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    out = Orchestrate.decide_outputs("detect", @versions, @jobs, states, nil, "2026-06-13", nil)
    assert out.any == true
    assert out.dry_run == false
    assert [%{name: "master", runner: "macos-26"}] = out.matrix["include"]
  end

  test "detect: unchanged => empty matrix, any=false (the gate)" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    manifest = %{"versions" => %{"master" => %{"upstream_sha" => "a", "inputs_hash" => "h"}}}
    out = Orchestrate.decide_outputs("detect", @versions, @jobs, states, manifest, "2026-06-13", nil)
    assert out.matrix == %{"include" => []}
    assert out.any == false
  end

  test "force: only the named version, any=true, dry_run=false" do
    out = Orchestrate.decide_outputs("force", @versions, @jobs, %{}, nil, "2026-06-13", "master")
    assert [%{name: "master"}] = out.matrix["include"]
    assert out.any == true and out.dry_run == false
  end

  test "dry-run: all enabled jobs, dry_run=true" do
    out = Orchestrate.decide_outputs("dry-run", @versions, @jobs, %{}, nil, "2026-06-13", nil)
    assert [%{name: "master"}] = out.matrix["include"]
    assert out.dry_run == true
  end

  test "finalize_outputs merges fragments and picks the last built tag" do
    frag = %{"versions" => %{"master" => %{"released_tag" => "emacs-master-2026-06-13"}}}
    out = Orchestrate.finalize_outputs(nil, [frag], ["emacs-master-2026-06-13"])
    assert out.latest_tag == "emacs-master-2026-06-13"
    assert out.manifest["versions"]["master"]["released_tag"] == "emacs-master-2026-06-13"
  end

  test "finalize_outputs with no built tags => latest_tag nil (no flip)" do
    out = Orchestrate.finalize_outputs(nil, [], [])
    assert out.latest_tag == nil
    assert out.manifest == %{"schema" => 1, "versions" => %{}}
  end
end
