defmodule Orchestrator.Upstream.GitLsRemoteTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Upstream.GitLsRemote, as: U

  test "parse/2 picks the refs/heads/<ref> sha" do
    out = "deadbeef\trefs/heads/master\ncafef00d\trefs/tags/v1\n"
    assert U.parse(out, "master") == "deadbeef"
  end

  test "parse/2 picks refs/tags/<ref> for a tag ref (ignoring the peeled ^{} row)" do
    out = "aaa111\trefs/tags/emacs-30.2\nbbb222\trefs/tags/emacs-30.2^{}\n"
    assert U.parse(out, "emacs-30.2") == "aaa111"
  end

  test "parse/2 falls back to the first row when no exact ref match" do
    assert U.parse("abc\trefs/heads/foo\n", "master") == "abc"
  end

  test "parse/2 returns nil for empty/whitespace output (unresolvable ⇒ skip, not rebuild)" do
    assert U.parse("", "master") == nil
    assert U.parse("\n", "master") == nil
  end
end
