defmodule Orchestrator.TerminfoTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Terminfo

  @prefix "/Users/runner/work/misemacs/misemacs/versions/master/.pixi/envs/default"
  @needle @prefix <> "/share/terminfo"
  @system "/usr/share/terminfo"

  test "replaces a NUL-terminated cstring and preserves byte length" do
    bin = <<1, 2>> <> @needle <> <<0>> <> <<3, 4>>
    assert {:ok, out, 1} = Terminfo.patch(bin, @needle, @system)
    assert byte_size(out) == byte_size(bin)

    assert out ==
             <<1, 2>> <>
               @system <>
               :binary.copy(<<0>>, byte_size(@needle) + 1 - byte_size(@system)) <> <<3, 4>>
  end

  test "the patched cstring reads as the system path" do
    {:ok, out, 1} = Terminfo.patch(@needle <> <<0>>, @needle, @system)
    assert [@system | _] = :binary.split(out, <<0>>)
  end

  test "counts and replaces every occurrence" do
    bin = @needle <> <<0>> <> "pad" <> @needle <> <<0>>
    assert {:ok, out, 2} = Terminfo.patch(bin, @needle, @system)
    assert :binary.matches(out, @needle) == []
  end

  # Padding a prefix match would truncate the longer string at the NUL we write.
  test "leaves a needle that is only a prefix of a longer cstring" do
    bin = @needle <> "/x" <> <<0>>
    assert :unchanged = Terminfo.patch(bin, @needle, @system)
  end

  test "unchanged when the needle is absent" do
    assert :unchanged = Terminfo.patch("no terminfo here" <> <<0>>, @needle, @system)
  end

  test "refuses a replacement that would not fit" do
    long = String.duplicate("x", byte_size(@needle) + 1)
    assert {:error, :replacement_too_long} = Terminfo.patch(@needle <> <<0>>, @needle, long)
  end

  # Equal-length replacement leaves exactly the terminating NUL.
  test "accepts a replacement the same length as the needle" do
    same = String.duplicate("y", byte_size(@needle))
    assert {:ok, out, 1} = Terminfo.patch(@needle <> <<0>>, @needle, same)
    assert out == same <> <<0>>
  end
end
