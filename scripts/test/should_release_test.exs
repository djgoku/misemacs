ExUnit.start()
Code.require_file("../cli/misemacs_lib.exs", __DIR__)

defmodule Misemacs.DecideTest do
  use ExUnit.Case, async: true
  alias Misemacs.Lib

  @off %{force: false, version_given: false}

  test "equal hashes => no rebuild" do
    refute Lib.decide("a", "a", @off)
  end

  test "different hashes => rebuild" do
    assert Lib.decide("a", "b", @off)
  end

  test "no prior release (nil or empty) => rebuild" do
    assert Lib.decide("a", nil, @off)
    assert Lib.decide("a", "", @off)
  end

  test "--force overrides an equal hash" do
    assert Lib.decide("a", "a", %{force: true, version_given: false})
  end

  test "explicit --version overrides an equal hash" do
    assert Lib.decide("a", "a", %{force: false, version_given: true})
  end
end
