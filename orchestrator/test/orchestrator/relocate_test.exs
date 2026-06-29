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

  # R8 stub: a fake Tool that returns macho?=true and a recorded fake dep ONLY for files
  # under the enchant subtree. This means: if Relocate.machos/2 were to pass an enchant-
  # subtree file to macho?/1 and it returned true, copy_closure would attempt to copy the
  # fake dep to Frameworks. The test asserts Frameworks is empty, proving machos/2 skipped
  # the enchant file (it was rejected before macho? was called). For non-enchant paths,
  # macho?/1 returns false so they don't trigger any copy either.
  defmodule RecordingTool do
    @behaviour Orchestrator.Macho.Tool
    @enchant_prefix "Contents/Resources/enchant/"

    def macho?(p) do
      String.contains?(p, @enchant_prefix)
    end

    # For an enchant file, return a fake bundleable dep (a non-existent @rpath ref) so that
    # copy_closure would try to resolve and copy it if machos/2 had passed the file through.
    def deps(p) do
      if String.contains?(p, @enchant_prefix),
        do: ["@rpath/libenchant_test_sentinel.dylib"],
        else: []
    end

    def rpaths(_), do: []
    def id(_), do: nil
    def set_id(_, _), do: :ok
    def change(_, _, _), do: :ok
    def add_rpath(_, _), do: :ok
    def delete_rpath(_, _), do: :ok
    def sign_bundle(_), do: :ok
    def sign_file(_), do: :ok
    def verify_bundle(_), do: :ok
    def verify_file(_), do: :ok
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

  # R8: real macOS integration test — an enchant dylib has a foreign dep that lives only in
  # the enchant sub-prefix (ench_lib), not in Contents/Frameworks. After Relocate.run the dep
  # must NOT appear in Contents/Frameworks, proving the Frameworks walk skipped the enchant
  # subtree and did not pull libenchdep into the app's shared Frameworks directory.
  @tag :macos
  test "Frameworks walk skips Contents/Resources/enchant — foreign dep of enchant dylib is NOT copied into Frameworks",
       %{t: t} do
    lib = Path.join(t, "buildlib")
    app = Path.join(t, "App.app")
    ench_lib = Path.join([app, "Contents", "Resources", "enchant", "lib"])
    File.mkdir_p!(ench_lib)

    File.write!(Path.join(t, "main.c"), "int main(void){return 0;}\n")
    File.write!(Path.join(t, "ench_dep.c"), "int ench_dep(void){return 1;}\n")
    File.write!(Path.join(t, "ench.c"), "int ench_dep(void); int e(void){return ench_dep();}\n")

    # Build the enchant dep dylib and place it ONLY in ench_lib (simulates staged sub-prefix;
    # nothing in buildlib or the main app references it, so the Frameworks walk cannot pull it)
    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libenchdep.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "ench_dep.c"),
      "-o",
      Path.join(ench_lib, "libenchdep.dylib")
    ])

    # Build the enchant dylib linking against the dep, with id/rpath already normalised to
    # the ench_lib location (simulates post-stage_copy state, ready for relocation)
    clang!([
      "-dynamiclib",
      "-install_name",
      "@rpath/libench.dylib",
      "-Wl,-headerpad_max_install_names",
      "-L",
      ench_lib,
      "-lenchdep",
      "-Wl,-rpath," <> ench_lib,
      Path.join(t, "ench.c"),
      "-o",
      Path.join(ench_lib, "libench.dylib")
    ])

    # App main binary has no enchant dep — just a minimal self-contained executable
    clang!([
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "main.c"),
      "-o",
      Path.join(app, "Contents/MacOS/App")
    ])

    assert Orchestrator.Relocate.run(app, lib) == :ok

    # Key assertion: libenchdep.dylib must NOT have been pulled into Contents/Frameworks.
    # (It lives in the enchant sub-prefix which the Frameworks walk must skip.)
    refute File.exists?(Path.join([app, "Contents", "Frameworks", "libenchdep.dylib"])),
           "libenchdep.dylib should NOT be in Frameworks — enchant subtree must be excluded from the walk"

    # Sanity: both enchant dylibs must still be in place in the sub-prefix
    assert File.exists?(Path.join(ench_lib, "libench.dylib")),
           "libench.dylib should remain in place under enchant/"

    assert File.exists?(Path.join(ench_lib, "libenchdep.dylib")),
           "libenchdep.dylib should remain in place under enchant/lib — not moved to Frameworks"
  end

  # R8: fast stub-tool unit test. RecordingTool.macho?/1 returns true for any path under
  # the enchant subtree and returns a fake bundleable dep from deps/1 for those files.
  # If Relocate.machos/2 were to pass an enchant-subtree file through to copy_closure,
  # that dep would be resolved from buildlib and copied to Contents/Frameworks.
  # The test asserts Contents/Frameworks is empty, proving machos/2 skipped the enchant
  # file (Enum.reject filtered it before macho? was even called). No real clang/codesign
  # needed — the stub's sign/verify callbacks are no-ops.
  @tag :macos
  test "machos/2 excludes enchant subtree — stub sentinel dep is NOT copied to Frameworks" do
    t = Path.join(System.tmp_dir!(), "reloc-stub-#{System.unique_integer([:positive])}")

    try do
      app = Path.join(t, "App.app")
      lib = Path.join(t, "buildlib")
      ench_lib = Path.join([app, "Contents", "Resources", "enchant", "lib"])
      File.mkdir_p!(ench_lib)
      File.mkdir_p!(Path.join([app, "Contents", "MacOS"]))
      # Create the sentinel dep in buildlib so copy_closure CAN resolve it if it tries
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, "libenchant_test_sentinel.dylib"), "fake sentinel")

      # Place a fake file in the enchant subtree
      File.write!(Path.join(ench_lib, "libench.dylib"), "fake")
      File.write!(Path.join([app, "Contents", "MacOS", "App"]), "fake")

      # Write a valid Info.plist
      File.write!(Path.join([app, "Contents", "Info.plist"]), """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleExecutable</key><string>App</string>
        <key>CFBundleIdentifier</key><string>com.test.stubreloc</string>
        <key>CFBundleName</key><string>App</string>
        <key>CFBundlePackageType</key><string>APPL</string>
      </dict>
      </plist>
      """)

      Orchestrator.Relocate.run(app, lib, RecordingTool)

      fw = Path.join([app, "Contents", "Frameworks"])

      assert not File.exists?(Path.join(fw, "libenchant_test_sentinel.dylib")),
             "sentinel dep must NOT appear in Frameworks — machos/2 must skip the enchant subtree"
    after
      File.rm_rf!(t)
    end
  end
end
