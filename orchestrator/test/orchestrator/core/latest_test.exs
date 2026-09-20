defmodule Orchestrator.Core.LatestTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Latest

  test "nothing built => :unchanged" do
    assert Latest.latest_target([]) == :unchanged
  end

  test "a single build becomes latest" do
    assert Latest.latest_target(["emacs-master-2026-06-05"]) == {:set, "emacs-master-2026-06-05"}
  end

  test "newest is the lexical max regardless of input order" do
    tags = ["emacs-31-2026-06-28", "emacs-31-2026-06-29", "emacs-31-2026-06-27"]
    assert Latest.latest_target(tags) == {:set, "emacs-31-2026-06-29"}
  end

  test "a legacy same-day .N collision suffix sorts newest" do
    tags = ["emacs-31-2026-06-29", "emacs-31-2026-06-29.1"]
    assert Latest.latest_target(tags) == {:set, "emacs-31-2026-06-29.1"}
  end

  test "packslip versions use numeric semver order across months and rebuilds" do
    tags = ["v2026.9.11", "v2026.10.0", "v2026.9.9"]
    assert Latest.latest_target(tags) == {:set, "v2026.10.0"}
  end
end
