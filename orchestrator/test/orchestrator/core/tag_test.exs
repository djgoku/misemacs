defmodule Orchestrator.Core.TagTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Core.Tag
  alias Orchestrator.Naming

  test "first build in a month has a discoverable semver tag" do
    tag = Tag.next_tag("master", "2026-09-20", ["emacs-master-2026-09-20"])
    assert tag == "v2026.9.0"
    assert Naming.packslip_version(tag) == "2026.9.0"

    assert Naming.asset_name(tag, "macos", "arm64") ==
             "misemacs-v2026.9.0-macos-arm64.tar.gz"
  end

  test "releases increment across days in the same month" do
    first = Tag.next_tag("master", "2026-09-20", [])
    second = Tag.next_tag("master", "2026-09-20", [first])
    tomorrow = Tag.next_tag("master", "2026-09-21", [first, second])
    assert second == "v2026.9.1"
    assert tomorrow == "v2026.9.2"
    assert Version.compare(Naming.packslip_version(first), Naming.packslip_version(second)) == :lt

    assert Version.compare(Naming.packslip_version(second), Naming.packslip_version(tomorrow)) ==
             :lt
  end

  test "collision gaps are not filled and malformed tags are ignored" do
    tags = ["v2026.9.0", "v2026.9.2", "v2026.9.2x", "v2026.10.20"]
    assert Tag.next_tag("31", "2026-09-20", tags) == "v2026.9.3"
  end

  test "the counter continues past nine releases in a month" do
    assert Tag.next_tag("master", "2026-09-20", ["v2026.9.9"]) == "v2026.9.10"
  end

  test "a new month resets the counter and still sorts after the prior month" do
    september = Tag.next_tag("master", "2026-09-30", ["v2026.9.12"])
    october = Tag.next_tag("master", "2026-10-01", [september, "v2026.9.12"])
    assert september == "v2026.9.13"
    assert october == "v2026.10.0"

    assert Version.compare(Naming.packslip_version(september), Naming.packslip_version(october)) ==
             :lt
  end

  test "a channel's repo isolates its versions" do
    assert Tag.next_tag("master", "2026-09-20", []) ==
             Tag.next_tag("31", "2026-09-20", [])
  end
end
