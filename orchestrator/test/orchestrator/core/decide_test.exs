defmodule Orchestrator.Core.DecideTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Decide
  alias Orchestrator.Core.Decide.Plan

  @versions [%{name: "master", channel: "master", ref: "master"}]

  test "first run builds everything (nil manifest)" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    plan = Decide.plan(@versions, states, nil, "2026-06-05")
    assert [%{name: "master", channel: "master", reason: :first_run}] = plan.build
    assert plan.skip == []
    assert plan.date == "2026-06-05"
  end

  test "no change => empty build, version skipped (the cadence rule)" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h"}}
    manifest = %{"versions" => %{"master" => %{"upstream_sha" => "a", "inputs_hash" => "h"}}}
    plan = Decide.plan(@versions, states, manifest, "2026-06-05")
    assert plan.build == []
    assert [%{name: "master", reason: :unchanged}] = plan.skip
  end

  test "changed inputs => build with :inputs" do
    states = %{"master" => %{upstream_sha: "a", inputs_hash: "h2"}}
    manifest = %{"versions" => %{"master" => %{"upstream_sha" => "a", "inputs_hash" => "h"}}}
    plan = Decide.plan(@versions, states, manifest, "2026-06-05")
    assert [%{name: "master", reason: :inputs}] = plan.build
  end

  test "mixed: one builds (upstream changed), one skips; build order preserved" do
    versions = [
      %{name: "master", channel: "master", ref: "master"},
      %{name: "emacs-30.2", channel: "30.2", ref: "emacs-30.2"}
    ]

    states = %{
      "master" => %{upstream_sha: "a2", inputs_hash: "h"},
      "emacs-30.2" => %{upstream_sha: "b", inputs_hash: "g"}
    }

    manifest = %{
      "versions" => %{
        "master" => %{"upstream_sha" => "a", "inputs_hash" => "h"},
        "emacs-30.2" => %{"upstream_sha" => "b", "inputs_hash" => "g"}
      }
    }

    plan = Decide.plan(versions, states, manifest, "2026-06-05")
    assert [%{name: "master", reason: :upstream_sha}] = plan.build
    assert [%{name: "emacs-30.2", reason: :unchanged}] = plan.skip
  end

  test "a version missing from current_states fails loud (KeyError)" do
    assert_raise KeyError, fn -> Decide.plan(@versions, %{}, nil, "2026-06-05") end
  end

  test "matrix/2 keeps only jobs whose version is in plan.build" do
    plan = %Plan{
      date: "2026-06-05",
      build: [%{name: "master", channel: "master", reason: :first_run, state: %{}}],
      skip: [%{name: "emacs-30.2", reason: :unchanged}]
    }

    jobs = [
      %{
        name: "master",
        channel: "master",
        ref: "master",
        target: "macos-arm64",
        os: "macos",
        arch: "arm64",
        runner: "macos-14"
      },
      %{
        name: "emacs-30.2",
        channel: "30.2",
        ref: "emacs-30.2",
        target: "macos-arm64",
        os: "macos",
        arch: "arm64",
        runner: "macos-14"
      }
    ]

    assert [%{name: "master"}] = Decide.matrix(plan, jobs)
  end

  test "force/3 builds only the named version with reason :forced" do
    versions = [
      %{name: "master", channel: "master", ref: "master"},
      %{name: "emacs-30.2", channel: "30.2", ref: "emacs-30.2"}
    ]

    plan = Decide.force(versions, "emacs-30.2", "2026-06-13")
    assert [%{name: "emacs-30.2", channel: "30.2", reason: :forced}] = plan.build
    assert [%{name: "master", reason: :not_forced}] = plan.skip
    assert plan.date == "2026-06-13"
  end

  test "force/3 raises for an unknown version" do
    assert_raise ArgumentError, fn -> Decide.force(@versions, "nope", "2026-06-13") end
  end
end
