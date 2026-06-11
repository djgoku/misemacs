defmodule Orchestrator.MachoTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Macho

  @otool_l """
  /p/App.app/Contents/MacOS/App:
  \t@rpath/libfoo.dylib (compatibility version 0.0.0, current version 0.0.0)
  \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
  """
  @otool_l_dylib """
  /build/lib/libfoo.dylib:
  \t@rpath/libfoo.dylib (compatibility version 0.0.0, current version 0.0.0)
  \t@rpath/libbar.dylib (compatibility version 0.0.0, current version 0.0.0)
  """
  @otool_d "/build/lib/libfoo.dylib:\n@rpath/libfoo.dylib\n"
  @otool_d_exe "/p/App.app/Contents/MacOS/App:\n"
  @otool_l_rpath """
  Load command 12
            cmd LC_RPATH
        cmdsize 32
           path /build dir/lib (offset 12)
  Load command 13
            cmd LC_RPATH
        cmdsize 40
           path @loader_path/../Frameworks (offset 12)
  """

  test "classify" do
    assert Macho.classify("/usr/lib/libSystem.B.dylib") == :system
    assert Macho.classify("/System/Library/Frameworks/AppKit") == :system
    assert Macho.classify("@rpath/libfoo.dylib") == :bundled
    assert Macho.classify("@loader_path/../Frameworks") == :bundled
    assert Macho.classify("/opt/homebrew/lib/libx.dylib") == :foreign
    assert Macho.classify("librelative.dylib") == :other
  end

  test "relpath" do
    assert Macho.relpath("/a/App/Contents/Frameworks", "/a/App/Contents/MacOS") == "../Frameworks"

    assert Macho.relpath("/a/App/Contents/Frameworks", "/a/App/Contents/MacOS/bin") ==
             "../../Frameworks"

    assert Macho.relpath("/a/App/Contents/Frameworks", "/a/App/Contents/Frameworks") == "."
  end

  test "parse_id" do
    assert Macho.parse_id(@otool_d) == "@rpath/libfoo.dylib"
    assert Macho.parse_id(@otool_d_exe) == nil
  end

  test "parse_deps excludes self id, keeps system + @rpath" do
    assert Macho.parse_deps(@otool_l, nil) ==
             ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib"]

    assert Macho.parse_deps(@otool_l_dylib, "@rpath/libfoo.dylib") == ["@rpath/libbar.dylib"]
  end

  test "parse_rpaths is space-tolerant" do
    assert Macho.parse_rpaths(@otool_l_rpath) == ["/build dir/lib", "@loader_path/../Frameworks"]
  end

  test "bundleable = foreign + @rpath only" do
    deps = ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib", "/opt/homebrew/lib/libx.dylib"]
    assert Macho.bundleable(deps) == ["@rpath/libfoo.dylib", "/opt/homebrew/lib/libx.dylib"]
  end

  test "gate_violations: foreign dep, missing @rpath lib, foreign rpath" do
    machos = [
      %{path: "exe", deps: ["@rpath/libfoo.dylib", "/opt/x/liby.dylib"], rpaths: ["/build/lib"]},
      %{
        path: "ok",
        deps: ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib"],
        rpaths: ["@loader_path/../Frameworks"]
      }
    ]

    fw = MapSet.new(["libfoo.dylib"])
    v = Macho.gate_violations(machos, fw)
    assert {:foreign_dep, "exe", "/opt/x/liby.dylib"} in v
    assert {:foreign_rpath, "exe", "/build/lib"} in v
    refute Enum.any?(v, &match?({:missing_lib, _, _}, &1))

    assert {:missing_lib, "z", "@rpath/libgone.dylib"} in Macho.gate_violations(
             [%{path: "z", deps: ["@rpath/libgone.dylib"], rpaths: []}],
             fw
           )
  end

  test "gate_violations empty == self-contained" do
    machos = [
      %{
        path: "ok",
        deps: ["@rpath/libfoo.dylib", "/usr/lib/libSystem.B.dylib"],
        rpaths: ["@loader_path/../Frameworks"]
      }
    ]

    assert Macho.gate_violations(machos, MapSet.new(["libfoo.dylib"])) == []
  end
end
