defmodule Orchestrator.Releases.GhTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Releases.Gh

  test "parse_manifest/1 decodes a schema-1 manifest" do
    json = ~s({"schema":1,"versions":{"master":{"upstream_sha":"a","inputs_hash":"h"}}})
    assert %{"versions" => %{"master" => %{"upstream_sha" => "a"}}} = Gh.parse_manifest(json)
  end

  test "parse_manifest/1 is nil for non-manifest / bad json / read error" do
    assert Gh.parse_manifest(~s({"no":"versions"})) == nil
    assert Gh.parse_manifest("not json") == nil
    assert Gh.parse_manifest({:error, :enoent}) == nil
  end

  test "parse_manifest/1 unwraps a {:ok, json} File.read result" do
    assert %{"versions" => _} = Gh.parse_manifest({:ok, ~s({"versions":{}})})
  end

  test "classify: list failed => :error" do
    assert {:error, _} = Gh.classify({:error, :gh_failed}, fn _tag -> :unused end)
  end

  test "classify: reachable, no tags => :empty" do
    assert Gh.classify({:ok, []}, fn _tag -> raise "should not fetch" end) == :empty
  end

  test "classify: tries newest tag first" do
    fetched =
      fn
        "emacs-31-2026-06-29" -> %{"versions" => %{"emacs-31" => %{}}}
        other -> flunk("newest tag has a manifest, should not have scanned to #{other}")
      end

    assert {:ok, %{"versions" => _}} =
             Gh.classify({:ok, ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]}, fetched)
  end

  test "classify: scans back past a manifest-less newest (in-flight release) to an older manifest" do
    # The newest tag is published this run but its manifest is attached later by finalize,
    # so the newest may legitimately lack one — fall back to the previous release's state.
    fetched =
      fn
        "emacs-31-2026-06-29" -> nil
        "emacs-31-2026-06-28" -> %{"versions" => %{"emacs-31" => %{"upstream_sha" => "old"}}}
      end

    assert {:ok, %{"versions" => %{"emacs-31" => %{"upstream_sha" => "old"}}}} =
             Gh.classify({:ok, ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]}, fetched)
  end

  test "classify: tags exist but none has a manifest => :empty (no-prior; self-heals, no deadlock)" do
    assert Gh.classify({:ok, ["emacs-31-2026-06-28", "emacs-31-2026-06-29"]}, fn _ -> nil end) ==
             :empty
  end
end
