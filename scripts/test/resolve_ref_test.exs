ExUnit.start()
Code.require_file("../cli/misemacs_lib.exs", __DIR__)

defmodule Misemacs.ResolveRefTest do
  use ExUnit.Case, async: true
  alias Misemacs.Lib

  test "single matching ref => {:ok, sha}" do
    assert Lib.parse_ls_remote("abc123\trefs/heads/master") == {:ok, "abc123"}
  end

  test "no matching ref => {:error, :none}" do
    assert Lib.parse_ls_remote("") == {:error, :none}
  end

  test "two refs with different shas => {:error, :ambiguous}" do
    out = "abc\trefs/heads/foo\ndef\trefs/tags/foo"
    assert Lib.parse_ls_remote(out) == {:error, :ambiguous}
  end

  test "two refs pointing at the same sha is unambiguous" do
    out = "abc\trefs/heads/foo\nabc\trefs/tags/foo"
    assert Lib.parse_ls_remote(out) == {:ok, "abc"}
  end
end
