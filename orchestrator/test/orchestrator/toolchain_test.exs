defmodule Orchestrator.Toolchain.MacosTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Toolchain.Macos

  @clang """
  Apple clang version 21.0.0 (clang-2100.1.1.101)
  Target: arm64-apple-darwin25.5.0
  Thread model: posix
  InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
  """

  test "normalize/3 keeps only the Apple-clang line and is stable for identical inputs" do
    h = Macos.normalize("/Applications/Xcode.app/Contents/Developer\n", @clang, "26.5\n")
    assert String.starts_with?(h, "sha256:")
    assert h == Macos.normalize("/Applications/Xcode.app/Contents/Developer", @clang, "26.5")
  end

  test "normalize/3 ignores the host-OS-volatile Target line" do
    a = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.5.0\n"
    b = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.6.0\n"
    assert Macos.normalize("/p", a, "26.5") == Macos.normalize("/p", b, "26.5")
  end

  test "normalize/3 flips on a clang-build, SDK, or developer-dir change" do
    base = Macos.normalize("/p", "Apple clang version 21.0.0 (clang-2100.1.1.101)\n", "26.5")
    assert base != Macos.normalize("/p", "Apple clang version 21.0.0 (clang-2100.1.1.102)\n", "26.5")
    assert base != Macos.normalize("/p", "Apple clang version 21.0.0 (clang-2100.1.1.101)\n", "26.6")
    assert base != Macos.normalize("/q", "Apple clang version 21.0.0 (clang-2100.1.1.101)\n", "26.5")
  end

  @tag :macos
  test "clt_fingerprint/0 captures a stable sha on a real macOS host (run-to-run)" do
    h = Macos.clt_fingerprint()
    assert String.starts_with?(h, "sha256:")
    assert h == Macos.clt_fingerprint()
  end
end
