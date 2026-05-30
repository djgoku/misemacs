ExUnit.start()
Code.require_file("../cli/misemacs_lib.exs", __DIR__)

defmodule Misemacs.VersionTest do
  use ExUnit.Case, async: true
  alias Misemacs.Lib

  test "parse_calver parses with and without suffix; rejects bad shape" do
    assert Lib.parse_calver("2026.05.30") == {2026, 5, 30, 0}
    assert Lib.parse_calver("2026.05.30.7") == {2026, 5, 30, 7}
    assert Lib.parse_calver("2026.05") == nil
    assert Lib.parse_calver("v2026.05.30") == nil
    assert Lib.parse_calver("2026.05.30.") == nil
  end

  test "valid_calver? mirrors parse_calver" do
    assert Lib.valid_calver?("2026.05.30")
    assert Lib.valid_calver?("2026.05.30.10")
    refute Lib.valid_calver?("2026.05")
    refute Lib.valid_calver?("v2026.05.30")
  end

  test "compare_calver orders numerically, not lexically" do
    assert Lib.compare_calver({2026, 5, 29, 10}, {2026, 5, 29, 9}) == :gt
    assert Lib.compare_calver({2026, 5, 29, 2}, {2026, 5, 29, 10}) == :lt
    assert Lib.compare_calver({2026, 5, 29, 0}, {2026, 5, 29, 0}) == :eq
  end

  test "latest_tag picks .10 over .9 and .2 (C1 regression)" do
    tags = [
      "emacs-master-2026.05.29",
      "emacs-master-2026.05.29.2",
      "emacs-master-2026.05.29.9",
      "emacs-master-2026.05.29.10",
      "emacs-mac-master-2027.01.01"
    ]
    assert Lib.latest_tag(tags, "emacs-master") == "emacs-master-2026.05.29.10"
  end

  test "latest_tag is prefix-exact and returns nil when none match" do
    # emacs-master- must NOT match emacs-mac-master-*
    assert Lib.latest_tag(["emacs-mac-master-2026.05.30"], "emacs-master") == nil
    assert Lib.latest_tag([], "emacs-master") == nil
  end

  test "next_calver returns today when free, else first free suffix" do
    assert Lib.next_calver("2026.05.30", MapSet.new()) == "2026.05.30"
    assert Lib.next_calver("2026.05.30", MapSet.new(["2026.05.30"])) == "2026.05.30.1"

    taken = MapSet.new(["2026.05.30", "2026.05.30.1", "2026.05.30.2"])
    assert Lib.next_calver("2026.05.30", taken) == "2026.05.30.3"
  end
end
