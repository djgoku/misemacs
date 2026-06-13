defmodule Orchestrator.Core.HashTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Hash

  @inputs %{
    toolchain_hash: "sha256:tc",
    upstream_sha: "deadbeef",
    mise_toml: "[env]\n",
    pixi_toml: "[project]\n",
    pixi_lock: "version: 6\n"
  }

  test "hash/1 is the known sha256, lowercase, prefixed" do
    assert Hash.hash("abc") ==
             "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "toolchain_hash/3 is stable and flips on any input incl. clt" do
    h = Hash.toolchain_hash("a", "b", "c")
    assert h == Hash.toolchain_hash("a", "b", "c")
    refute h == Hash.toolchain_hash("a", "b2", "c")
    refute h == Hash.toolchain_hash("a2", "b", "c")
    refute h == Hash.toolchain_hash("a", "b", "c2")
  end

  test "version_fingerprint is stable for identical inputs" do
    assert Hash.version_fingerprint(@inputs) == Hash.version_fingerprint(@inputs)
  end

  test "a change in ANY fingerprint field flips the fingerprint" do
    for field <- Hash.fingerprint_fields() do
      changed = Map.update!(@inputs, field, &(&1 <> "X"))

      refute Hash.version_fingerprint(@inputs) == Hash.version_fingerprint(changed),
             "expected a #{field} change to flip the fingerprint"
    end
  end

  test "version_fingerprint requires the full §8 field set (fail-loud)" do
    assert_raise KeyError, fn -> Hash.version_fingerprint(Map.delete(@inputs, :pixi_lock)) end
  end

  test "the frozen field order matches spec §8" do
    assert Hash.fingerprint_fields() ==
             [:toolchain_hash, :upstream_sha, :mise_toml, :pixi_toml, :pixi_lock]
  end

  test "ordered fingerprint/1 is label-delimited (no field-boundary collision)" do
    refute Hash.fingerprint([{"f", "a"}, {"g", "b"}]) ==
             Hash.fingerprint([{"f", "ab"}, {"g", ""}])
  end
end
