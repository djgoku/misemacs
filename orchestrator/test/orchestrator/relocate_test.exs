defmodule Orchestrator.RelocateTest do
  use ExUnit.Case, async: false
  @moduletag :macos

  # Simulates a post-sign bundle mutation: signs for real, then tampers a sealed
  # dylib — verify_bundle must catch this (spec 2026-06-11 §3.1).
  defmodule TamperAfterSignTool do
    @behaviour Orchestrator.Macho.Tool
    alias Orchestrator.Macho.Otool
    defdelegate macho?(p), to: Otool
    defdelegate id(p), to: Otool
    defdelegate deps(p), to: Otool
    defdelegate rpaths(p), to: Otool
    defdelegate set_id(p, new), to: Otool
    defdelegate change(p, old, new), to: Otool
    defdelegate add_rpath(p, rp), to: Otool
    defdelegate delete_rpath(p, rp), to: Otool
    defdelegate verify_bundle(p), to: Otool
    defdelegate sign_file(p), to: Otool
    defdelegate verify_file(p), to: Otool

    def sign_bundle(app) do
      :ok = Otool.sign_bundle(app)
      tampered = Path.join([app, "Contents", "Frameworks", "libfoo.dylib"])
      File.write!(tampered, <<0>>, [:append])
      :ok
    end
  end

  setup do
    t = Path.join(System.tmp_dir!(), "reloc-#{System.unique_integer([:positive])}")
    app = Path.join(t, "App.app")
    File.mkdir_p!(Path.join([t, "buildlib"]))
    File.mkdir_p!(Path.join([app, "Contents", "MacOS", "bin"]))

    # A valid bundle requires Info.plist so codesign --deep doesn't complain about bundle format
    File.write!(Path.join([app, "Contents", "Info.plist"]), """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key><string>App</string>
      <key>CFBundleIdentifier</key><string>com.test.relocate</string>
      <key>CFBundleName</key><string>App</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict>
    </plist>
    """)

    # A nested non-Mach-O helper reproduces the original failure: per-file signing of the
    # main executable would trigger bundle mode and fail on this unsigned non-Mach-O helper
    File.mkdir_p!(Path.join([app, "Contents", "MacOS", "libexec"]))
    script = Path.join([app, "Contents", "MacOS", "libexec", "helper.sh"])
    File.write!(script, "#!/bin/sh\necho hi\n")
    File.chmod!(script, 0o755)

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

    assert {_, 0} =
             System.cmd("codesign", ["--verify", "--deep", "--strict", app],
               stderr_to_stdout: true
             )

    {dv, 0} = System.cmd("codesign", ["-dv", app], stderr_to_stdout: true)
    assert dv =~ "Signature=adhoc"
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

    assert {_, 0} =
             System.cmd("codesign", ["--verify", "--deep", "--strict", app],
               stderr_to_stdout: true
             )

    assert File.exists?(Path.join([app, "Contents", "Frameworks", "libabs.dylib"]))
    deps = Orchestrator.Macho.Otool.deps(app_bin)
    # the absolute ref was rewritten
    assert "@rpath/libabs.dylib" in deps
    refute abs in deps

    # clean-machine proxy
    File.rename!(lib, lib <> ".gone")
    assert {_, 0} = System.cmd(app_bin, [], stderr_to_stdout: true)
  end

  test "relocate fails with {:signature_invalid, _} when the bundle is mutated after signing",
       %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    File.write!(Path.join(t, "bar.c"), "int bar(void){return 5;}\n")
    File.write!(Path.join(t, "main.c"), "int bar(void); int main(void){return bar()-5;}\n")

    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libfoo.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "bar.c"),
      "-o",
      Path.join(lib, "libfoo.dylib")
    ])

    clang!([
      "-Wl,-headerpad_max_install_names",
      "-L",
      lib,
      "-lfoo",
      "-Wl,-rpath," <> lib,
      Path.join(t, "main.c"),
      "-o",
      Path.join(app, "Contents/MacOS/App")
    ])

    assert {:error, {:signature_invalid, reason}} =
             Orchestrator.Relocate.run(app, lib, TamperAfterSignTool)

    assert reason =~ "failed strict validation"
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
