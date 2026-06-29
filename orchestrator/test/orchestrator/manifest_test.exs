defmodule Orchestrator.ManifestTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Manifest

  @fixtures Path.expand("../support/fixtures", __DIR__)
  @repo_root Path.expand("../../..", __DIR__)

  test "jobs/3 crosses versions × enabled targets" do
    versions = %{
      "master" => %{"channel" => "master", "ref" => "master"},
      "emacs-30.2" => %{"channel" => "30.2", "ref" => "emacs-30.2"}
    }

    targets = %{
      "macos-arm64" => %{
        "os" => "macos",
        "arch" => "arm64",
        "runner" => "macos-14",
        "enabled" => true
      }
    }

    jobs = Manifest.jobs(versions, targets, "djgoku/misemacs")
    assert length(jobs) == 2
    assert Enum.any?(jobs, &(&1.name == "master" and &1.os == "macos" and &1.arch == "arm64"))
    assert Enum.any?(jobs, &(&1.name == "emacs-30.2" and &1.channel == "30.2"))
  end

  test "jobs/3 omits disabled targets" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}

    targets = %{
      "macos-arm64" => %{
        "os" => "macos",
        "arch" => "arm64",
        "runner" => "macos-14",
        "enabled" => true
      },
      "linux-arm64" => %{
        "os" => "linux",
        "arch" => "arm64",
        "runner" => "ubuntu-24.04-arm",
        "enabled" => false
      }
    }

    jobs = Manifest.jobs(versions, targets, "djgoku/misemacs")
    assert length(jobs) == 1
    assert hd(jobs).target == "macos-arm64"
  end

  test "a target without explicit enabled=true is omitted (fail-closed)" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}
    targets = %{"macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-14"}}
    assert Manifest.jobs(versions, targets, "djgoku/misemacs") == []
  end

  test "job.name equals the version table key (join-key invariant)" do
    versions = %{"emacs-30.2" => %{"channel" => "30.2", "ref" => "emacs-30.2"}}

    targets = %{
      "macos-arm64" => %{
        "os" => "macos",
        "arch" => "arm64",
        "runner" => "macos-14",
        "enabled" => true
      }
    }

    [job] = Manifest.jobs(versions, targets, "djgoku/misemacs")
    assert job.name == "emacs-30.2"
    assert job.name == job.ref
  end

  test "load/3 parses TOML fixtures into a job list" do
    {:ok, jobs} =
      Manifest.load(
        Path.join(@fixtures, "versions.toml"),
        Path.join(@fixtures, "targets.toml"),
        "djgoku/misemacs"
      )

    # 2 versions × 1 enabled target (linux disabled)
    assert length(jobs) == 2
    assert Enum.all?(jobs, &(&1.target == "macos-arm64"))
  end

  test "the committed repo-root manifest parses and includes master/macos-arm64" do
    {:ok, jobs} =
      Manifest.load(
        Path.join(@repo_root, "versions.toml"),
        Path.join(@repo_root, "targets.toml"),
        "djgoku/misemacs"
      )

    assert Enum.any?(jobs, &(&1.name == "master" and &1.target == "macos-arm64"))
  end

  test "versions!/1 reads the [%{name,channel,ref}] list from versions.toml under root" do
    vs = Manifest.versions!(@fixtures)
    assert %{name: "master", channel: "master", ref: "master"} in vs
    assert Enum.any?(vs, &(&1.name == "emacs-30.2" and &1.channel == "30.2"))
  end

  test "merge/2 with nil prior starts from the fragments (first run)" do
    frag = %{"schema" => 1, "versions" => %{"master" => %{"released_tag" => "t1"}}}

    assert Manifest.merge(nil, [frag]) ==
             %{"schema" => 1, "versions" => %{"master" => %{"released_tag" => "t1"}}}
  end

  test "merge/2 adds new version entries to the prior, fragments winning" do
    prior = %{
      "schema" => 1,
      "versions" => %{
        "master" => %{"released_tag" => "old"},
        "emacs-30.2" => %{"released_tag" => "keep"}
      }
    }

    merged = Manifest.merge(prior, [%{"versions" => %{"master" => %{"released_tag" => "new"}}}])
    assert merged["versions"]["master"]["released_tag"] == "new"
    assert merged["versions"]["emacs-30.2"]["released_tag"] == "keep"
  end

  test "merge/2 with no fragments preserves the prior versions" do
    prior = %{"schema" => 1, "versions" => %{"master" => %{"released_tag" => "t"}}}
    assert Manifest.merge(prior, []) == prior
  end

  test "jobs/3 stamps the per-channel artifact repo onto every cell" do
    versions = %{"master" => %{"channel" => "master", "ref" => "master"}}
    targets = %{"macos-arm64" => %{"os" => "macos", "arch" => "arm64", "runner" => "macos-26", "enabled" => true}}

    [job] = Orchestrator.Manifest.jobs(versions, targets, "djgoku/misemacs")
    assert job.repo == "djgoku/misemacs-emacs-master"
    assert job.channel == "master"
  end
end
