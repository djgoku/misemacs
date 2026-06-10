defmodule Orchestrator.RelocateTest do
  use ExUnit.Case, async: false
  @moduletag :macos

  setup do
    t = Path.join(System.tmp_dir!(), "reloc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([t, "buildlib"]))
    File.mkdir_p!(Path.join([t, "App.app", "Contents", "MacOS", "bin"]))
    on_exit(fn -> File.rm_rf!(t) end)
    {:ok, t: t}
  end

  defp clang!(args), do: {_, 0} = System.cmd("clang", args, stderr_to_stdout: true)

  test "relocate makes a fixture bundle self-contained; runs with build libdir moved aside", %{
    t: t
  } do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "foo.c"), "int bar(void); int foo(void){return bar()+2;}\n")
    File.write!(Path.join(t, "main.c"), "int foo(void); int main(void){return foo()-7;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libbar.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libbar.dylib")
    ])

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libfoo.dylib",
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lbar",
      "-Wl,-rpath," <> lib,
      Path.join(t, "foo.c"),
      "-o",
      Path.join(lib, "libfoo.dylib")
    ])

    for out <- ["Contents/MacOS/App", "Contents/MacOS/bin/helper"] do
      clang!([
        "-Wl,-headerpad_max_install_names",
        "-L",
        lib,
        "-lfoo",
        "-Wl,-rpath," <> lib,
        Path.join(t, "main.c"),
        "-o",
        Path.join(app, out)
      ])
    end

    assert Orchestrator.Relocate.run(app, lib) == :ok
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libfoo.dylib"]))
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libbar.dylib"]))

    # clean-machine proxy: remove the build libdir; both binaries must still run (rc 0 == foo()==7).
    File.rename!(lib, lib <> ".gone")

    for out <- ["Contents/MacOS/App", "Contents/MacOS/bin/helper"] do
      assert {_, 0} = System.cmd(Path.join(app, out), [], stderr_to_stdout: true)
    end
  end

  test "relocate rewrites a foreign-absolute install_name dep to @rpath and bundles it", %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "mainabs.c"), "int bar(void); int main(void){return bar()-5;}\n")
    abs = Path.join(lib, "libabs.dylib")
    # ABSOLUTE install_name (a foreign path), NOT @rpath:
    clang!([
      "-dynamiclib",
      "-install_name",
      abs,
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      abs
    ])

    app_bin = Path.join(app, "Contents/MacOS/App")

    clang!([
      "-Wl,-headerpad_max_install_names",
      abs,
      Path.join(t, "mainabs.c"),
      "-o",
      app_bin
    ])

    # sanity: dep is foreign-absolute
    assert Orchestrator.Macho.classify(abs) == :foreign

    assert Orchestrator.Relocate.run(app, lib) == :ok
    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libabs.dylib"]))
    deps = Orchestrator.Macho.Otool.deps(app_bin)
    # the absolute ref was rewritten
    assert "@rpath/libabs.dylib" in deps
    refute abs in deps

    # clean-machine proxy
    File.rename!(lib, lib <> ".gone")
    assert {_, 0} = System.cmd(app_bin, [], stderr_to_stdout: true)
  end

  test "relocate returns {:error, violations} when a dep cannot be resolved", %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "mainmiss.c"), "int bar(void); int main(void){return bar()-5;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libmissing.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libmissing.dylib")
    ])

    app_bin = Path.join(app, "Contents/MacOS/App")

    clang!([
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lmissing",
      "-Wl,-rpath," <> lib,
      Path.join(t, "mainmiss.c"),
      "-o",
      app_bin
    ])

    # so relocation cannot resolve it
    File.rm!(Path.join(lib, "libmissing.dylib"))

    assert {:error, violations} = Orchestrator.Relocate.run(app, lib)
    assert Enum.any?(violations, &match?({:missing_lib, _, "@rpath/libmissing.dylib"}, &1))
  end
end
