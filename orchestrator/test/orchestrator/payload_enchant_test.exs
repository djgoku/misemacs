# A tool stub that reports no Mach-O dependencies, so stage_copy/3's closure walk is a no-op.
# stage_copy only calls `tool.deps/1`, letting the copy-only staging logic be exercised on plain
# files with no clang/Mach-O fixtures (the install_name/sign IO is relocate/2's job, not stage_copy).
defmodule Orchestrator.Payload.EnchantTest.NoDepsTool do
  def deps(_path), do: []
end

defmodule Orchestrator.Payload.EnchantTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Payload.Enchant
  alias Orchestrator.Payload.EnchantTest.NoDepsTool

  test "pc_contents is ${pcfiledir}-relocatable and injects an rpath" do
    pc = Enchant.pc_contents()
    assert pc =~ "prefix=${pcfiledir}/../.."
    assert pc =~ "libdir=${prefix}/lib"
    assert pc =~ "includedir=${prefix}/include"
    assert pc =~ "Libs: -L${libdir} -lenchant-2 -Wl,-rpath,${libdir}"
    assert pc =~ "Cflags: -I${includedir}/enchant-2"
    refute pc =~ ~r{/(private|Users|opt|envs)/}, "no absolute build path may leak into the .pc"
  end

  test "pkgconfig_shim self-locates, emits rpath, and refuses non-enchant-2 queries" do
    sh = Enchant.pkgconfig_shim()
    assert sh =~ "#!/bin/sh"
    assert sh =~ ~s{prefix=$(cd "$(dirname "$0")/.." && pwd)}
    assert sh =~ "-I$prefix/include/enchant-2"
    assert sh =~ "-L$prefix/lib -lenchant-2 -Wl,-rpath,$prefix/lib"
    # O2: must not blindly answer for arbitrary packages
    assert sh =~ "enchant-2"
    assert sh =~ "exit 1"
  end

  test "pkgconfig_shim accepts enchant-2 and refuses any other package" do
    t = Path.join(System.tmp_dir!(), "shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(t)
    shim = Path.join(t, "pkg-config")
    on_exit(fn -> File.rm_rf!(t) end)
    File.write!(shim, Enchant.pkgconfig_shim())
    File.chmod!(shim, 0o755)

    # Accepted: enchant-2 query exits 0 and emits -lenchant-2.
    {out, status} = System.cmd(shim, ["--cflags", "--libs", "enchant-2"], stderr_to_stdout: true)
    assert status == 0, "expected exit 0 for enchant-2, got #{status}; output: #{out}"
    assert out =~ "-lenchant-2"

    # Refused: any other package exits non-zero (O2 refusal path).
    {_out, refused_status} =
      System.cmd(shim, ["--cflags", "--libs", "some-other-pkg"], stderr_to_stdout: true)

    assert refused_status != 0, "expected non-zero exit for some-other-pkg, got 0"
  end

  test "site_start_el is discovery-only, jinx-scoped, and self-heals stale rpaths" do
    el = Enchant.site_start_el()
    assert el =~ "with-eval-after-load 'jinx"
    assert el =~ "fboundp 'jinx--load-module"
    assert el =~ "advice-add 'jinx--load-module"
    # spike-3 rpath-patch self-heal
    assert el =~ "install_name_tool"
    # opt-out (O5)
    assert el =~ "misemacs-enchant-disable"
    refute el =~ "ispell-program-name", "discovery-only: must not set policy"
    refute el =~ "DYLD_FALLBACK_LIBRARY_PATH", "spike-2: dead, must not appear"
  end

  test "ordering_contents makes applespell default" do
    assert Enchant.ordering_contents() == "*:applespell,hunspell\n"
  end

  test "stage_copy raises if the applespell provider is staged without AppleSpell.config" do
    t = Path.join(System.tmp_dir!(), "ench-noconf-#{System.unique_integer([:positive])}")
    lib = Path.join(t, "conda/lib")
    File.mkdir_p!(Path.join(lib, "enchant-2"))
    app = Path.join(t, "Emacs.app")
    File.mkdir_p!(Path.join([app, "Contents", "Resources", "site-lisp"]))
    on_exit(fn -> File.rm_rf!(t) end)

    # Plain (non-Mach-O) stand-ins: stage_copy copies these and walks deps via the stub tool.
    # No AppleSpell.config is written under conda/share — so staging must fail loudly.
    File.write!(Path.join(lib, "libenchant-2.2.dylib"), "stub")
    File.write!(Path.join(lib, "enchant-2/enchant_applespell.so"), "stub")

    assert_raise RuntimeError, ~r/AppleSpell\.config is missing/, fn ->
      Enchant.stage_copy(app, Path.join(t, "conda"), NoDepsTool)
    end
  end

  @tag :macos
  test "Otool.sign_file then verify_file round-trips on a freshly-edited dylib" do
    t = Path.join(System.tmp_dir!(), "sf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(t)
    on_exit(fn -> File.rm_rf!(t) end)
    src = Path.join(t, "x.c")
    dy = Path.join(t, "libx.dylib")
    File.write!(src, "int x(void){return 1;}\n")

    {_, 0} =
      System.cmd("clang", ["-dynamiclib", "-install_name", "@rpath/libx.dylib", src, "-o", dy])

    # install_name edit invalidates/relinker-signs; verify_file then sign_file must yield a strict-valid sig
    {_, 0} =
      System.cmd("install_name_tool", ["-id", "@rpath/libx.dylib", dy], stderr_to_stdout: true)

    assert :ok = Orchestrator.Macho.Otool.sign_file(dy)
    assert :ok = Orchestrator.Macho.Otool.verify_file(dy)
  end

  @tag :macos
  test "stage+relocate a synthetic enchant sub-prefix → self-contained; jinx-stub compiles & loads" do
    import Bitwise

    tool = Orchestrator.Macho.Otool
    t = Path.join(System.tmp_dir!(), "ench-#{System.unique_integer([:positive])}")
    libdir = Path.join(t, "conda/lib")
    incdir = Path.join(t, "conda/include/enchant-2")
    File.mkdir_p!(Path.join(libdir, "enchant-2"))
    File.mkdir_p!(incdir)
    app = Path.join(t, "Emacs.app")
    File.mkdir_p!(Path.join([app, "Contents", "Resources", "site-lisp"]))
    on_exit(fn -> File.rm_rf!(t) end)
    cl = fn args -> {_, 0} = System.cmd("clang", args, stderr_to_stdout: true) end

    # synthetic conda enchant prefix: libglibstub (leaf), libenchant-2.2 (links glibstub),
    # unversioned symlink, a provider that links libenchant, a header, the .pc, the CLI.
    File.write!(Path.join(t, "g.c"), "int gstub(void){return 1;}\n")
    File.write!(Path.join(t, "e.c"), "int gstub(void); int enchant_v(void){return gstub()+1;}\n")
    File.write!(Path.join(t, "p.c"), "int enchant_v(void); int prov(void){return enchant_v();}\n")

    cl.([
      "-dynamiclib",
      "-install_name",
      "@rpath/libglibstub.dylib",
      "-Wl,-headerpad_max_install_names",
      Path.join(t, "g.c"),
      "-o",
      Path.join(libdir, "libglibstub.dylib")
    ])

    cl.([
      "-dynamiclib",
      "-install_name",
      "@rpath/libenchant-2.2.dylib",
      "-Wl,-headerpad_max_install_names",
      "-L",
      libdir,
      "-lglibstub",
      "-Wl,-rpath," <> libdir,
      Path.join(t, "e.c"),
      "-o",
      Path.join(libdir, "libenchant-2.2.dylib")
    ])

    File.ln_s!("libenchant-2.2.dylib", Path.join(libdir, "libenchant-2.dylib"))

    cl.([
      "-bundle",
      "-Wl,-headerpad_max_install_names",
      "-L",
      libdir,
      "-lenchant-2",
      "-Wl,-rpath," <> libdir,
      Path.join(t, "p.c"),
      "-o",
      Path.join([libdir, "enchant-2", "enchant_applespell.so"])
    ])

    File.write!(Path.join(incdir, "enchant.h"), "int enchant_v(void);\n")

    pc = Path.join([t, "conda/lib/pkgconfig/enchant-2.pc"])
    File.mkdir_p!(Path.dirname(pc))
    File.write!(pc, "prefix=#{Path.join(t, "conda")}\nLibs: -L${prefix}/lib -lenchant-2\n")

    bindir = Path.join(t, "conda/bin")
    File.mkdir_p!(bindir)

    for b <- ["enchant-2", "enchant-lsmod-2"] do
      File.write!(
        Path.join(t, "#{b}.c"),
        "int enchant_v(void); int main(void){return enchant_v()-2;}\n"
      )

      cl.([
        "-Wl,-headerpad_max_install_names",
        "-L",
        libdir,
        "-lenchant-2",
        "-Wl,-rpath," <> libdir,
        Path.join(t, "#{b}.c"),
        "-o",
        Path.join(bindir, b)
      ])
    end

    conda = Path.join(t, "conda")

    # The feedstock ships an applespell locale map at share/enchant-2/AppleSpell.config.
    # Staging MUST copy it (root-cause of the en_US SEGFAULT + dict_exists=0 was dropping it):
    # without it applespell claims no locale and enchant falls back to a crashing bare-lang tag.
    File.mkdir_p!(Path.join(conda, "share/enchant-2"))
    File.write!(Path.join(conda, "share/enchant-2/AppleSpell.config"), "en_US\ten\tEnglish\n")

    assert :ok = Orchestrator.Payload.Enchant.stage_copy(app, conda, tool)
    assert :ok = Orchestrator.Payload.Enchant.relocate(app, tool)
    assert :ok = Orchestrator.Payload.Enchant.verify(app, conda, tool)

    ench = Path.join(app, "Contents/Resources/enchant")
    assert File.exists?(Path.join(ench, "lib/libenchant-2.2.dylib"))
    # unversioned symlink (spike-A)
    assert File.exists?(Path.join(ench, "lib/libenchant-2.dylib"))
    # closure pulled into enchant/lib
    assert File.exists?(Path.join(ench, "lib/libglibstub.dylib"))
    assert File.exists?(Path.join(ench, "lib/enchant-2/enchant_applespell.so"))
    assert File.exists?(Path.join(ench, "share/enchant-2/enchant.ordering"))
    assert File.exists?(Path.join(app, "Contents/Resources/site-lisp/site-start.el"))

    # AppleSpell.config copied from the conda prefix → applespell can claim en_US (no crash).
    assert File.read!(Path.join(ench, "share/enchant-2/AppleSpell.config")) =~ "en_US"

    # No Hunspell dictionaries are bundled (applespell default; hunspell is bring-your-own).
    refute File.dir?(Path.join(ench, "share/hunspell"))

    # R9: each staged CLI is executable.
    for b <- ["enchant-2", "enchant-lsmod-2", "pkg-config"] do
      p = Path.join(ench, "bin/#{b}")
      assert File.exists?(p)
      assert band(File.stat!(p).mode, 0o111) != 0, "#{b} must be executable"
    end

    # R9: each provider .so is signed, has no foreign deps/rpaths, and no @rpath dep on another provider.
    for so <- Path.wildcard(Path.join(ench, "lib/enchant-2/*.so")) do
      assert tool.verify_file(so) == :ok, "#{so} must carry a valid ad-hoc signature"

      assert Enum.all?(tool.deps(so), &(Orchestrator.Macho.classify(&1) != :foreign)),
             "#{so} must have no foreign deps"

      assert Enum.all?(tool.rpaths(so), &(Orchestrator.Macho.classify(&1) != :foreign)),
             "#{so} must have no foreign rpaths"

      refute Enum.any?(tool.deps(so), fn d ->
               String.starts_with?(d, "@rpath/") and String.ends_with?(d, ".so")
             end),
             "#{so} must not @rpath-depend on another provider"
    end

    # jinx-stub: jinx's real compile flags + the bundled shim → compile, link, dlopen.
    File.write!(
      Path.join(t, "jinx-mod.c"),
      "int enchant_v(void); int jinx_probe(void){return enchant_v()+40;}\n"
    )

    pkgout =
      System.cmd(Path.join(ench, "bin/pkg-config"), ["--cflags", "--libs", "enchant-2"])
      |> elem(0)
      |> String.trim()
      |> String.split()

    cl.(
      [
        "-I.",
        "-O2",
        "-Wall",
        "-Wextra",
        "-fPIC",
        "-shared",
        "-o",
        Path.join(t, "jinx-mod.so"),
        Path.join(t, "jinx-mod.c")
      ] ++ pkgout
    )

    File.write!(
      Path.join(t, "host.c"),
      ~S|#include <dlfcn.h>
#include <stdio.h>
int main(int c,char**v){void*h=dlopen(v[1],RTLD_NOW);if(!h){printf("FAIL %s\n",dlerror());return 1;}
int(*f)(void)=(int(*)(void))dlsym(h,"jinx_probe");return f()==42?0:3;}|
    )

    cl.(["-o", Path.join(t, "host"), Path.join(t, "host.c")])

    assert {_, 0} =
             System.cmd(Path.join(t, "host"), [Path.join(t, "jinx-mod.so")],
               stderr_to_stdout: true
             )
  end
end
