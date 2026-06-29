defmodule Orchestrator.Payload.EnchantTest do
  use ExUnit.Case, async: true
  alias Orchestrator.Payload.Enchant

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
end
