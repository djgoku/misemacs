defmodule OrchestratorTest do
  use ExUnit.Case, async: true

  test "toolchain is wired (known empty-string sha256)" do
    assert :crypto.hash(:sha256, "") |> Base.encode16(case: :lower) ==
             "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  end
end
