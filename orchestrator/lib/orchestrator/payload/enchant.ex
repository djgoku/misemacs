defmodule Orchestrator.Payload.Enchant do
  @moduledoc """
  The bundled-enchant companion payload. enchant is staged as a self-contained sub-prefix at
  `Emacs.app/Contents/Resources/enchant/` and relocated with **bundle-root = `enchant/lib`**
  (NOT `Contents/Frameworks`), because the feedstock's `dladdr` self-relocation requires
  `<prefix>/lib/libenchant-2.2.dylib` + `<prefix>/lib/enchant-2/` (design §5.1/§7).

  Pure here: the exact bytes of the four generated files. The copy/relocate/sign IO is the
  `stage/3` + `verify/2` runner (reuses `Orchestrator.Macho`, IO via `Orchestrator.Macho.Tool`).
  """
  alias Orchestrator.Macho

  @enchant_rel "Contents/Resources/enchant"
  @doc "Sub-prefix dir, relative to the app bundle root."
  @spec enchant_rel() :: String.t()
  def enchant_rel, do: @enchant_rel

  @doc "Relocatable `enchant-2.pc` (design §9): `${pcfiledir}`-relative, rpath injected into Libs."
  @spec pc_contents() :: String.t()
  def pc_contents do
    """
    prefix=${pcfiledir}/../..
    exec_prefix=${prefix}
    libdir=${prefix}/lib
    includedir=${prefix}/include

    Name: libenchant
    Description: A spell checking library
    Version: 2.8.2
    Libs: -L${libdir} -lenchant-2 -Wl,-rpath,${libdir}
    Cflags: -I${includedir}/enchant-2
    """
  end

  @doc """
  Minimal self-locating `pkg-config` shim (design §10). Answers ONLY `enchant-2` (O2: refuses
  anything else so it can't shadow a real pkg-config) and emits `-Wl,-rpath` so jinx's compiled
  module resolves libenchant from the bundle. Scoped to jinx's compile by `site_start_el/0`.
  """
  @spec pkgconfig_shim() :: String.t()
  def pkgconfig_shim do
    """
    #!/bin/sh
    # misemacs bundled pkg-config shim — answers `enchant-2` only (scoped to jinx via site-start).
    case " $* " in
      *" enchant-2 "*) : ;;
      *) echo "misemacs pkg-config shim: only 'enchant-2' is supported" >&2; exit 1 ;;
    esac
    prefix=$(cd "$(dirname "$0")/.." && pwd)
    out=""
    for a in "$@"; do
      case "$a" in
        --cflags) out="$out -I$prefix/include/enchant-2" ;;
        --libs)   out="$out -L$prefix/lib -lenchant-2 -Wl,-rpath,$prefix/lib" ;;
      esac
    done
    echo $out
    """
  end

  @doc """
  `site-start.el` (design §11). Discovery-only — adds nothing unless jinx loads, sets no policy.
  (1) scopes the `pkg-config` shim onto `exec-path` for jinx's module compile;
  (2) self-heals a stale embedded enchant rpath in place via `install_name_tool -rpath`
      (spike-3: recompile-free, arm64 auto re-signs) after an Emacs update moved the app path.
  Opt out with `(setq misemacs-enchant-disable t)` or `emacs -Q` / `--no-site-file`.
  """
  @spec site_start_el() :: String.t()
  def site_start_el do
    ~S"""
    ;;; site-start.el --- misemacs: compile jinx against the bundled enchant  -*- lexical-binding: t; -*-
    (defun misemacs--enchant-rpath-fix (mod lib)
      "Repoint any stale enchant LC_RPATH in MOD to LIB (install_name_tool re-signs on arm64)."
      (with-temp-buffer
        (when (eq 0 (call-process "otool" nil t nil "-l" mod))
          (goto-char (point-min))
          (while (re-search-forward "path \\(.*/Contents/Resources/enchant/lib\\) (offset" nil t)
            (let ((old (match-string 1)))
              (unless (string= old lib)
                (call-process "install_name_tool" nil nil nil "-rpath" old lib mod)))))))
    (unless (bound-and-true-p misemacs-enchant-disable)
      (let* ((app (expand-file-name "../../.." (file-name-directory load-file-name)))
             (ench (expand-file-name "Contents/Resources/enchant" app))
             (bin (expand-file-name "bin" ench))
             (lib (expand-file-name "lib" ench)))
        (with-eval-after-load 'jinx
          (when (fboundp 'jinx--load-module)
            (advice-add 'jinx--load-module :around
                        (lambda (orig &rest args)
                          (let ((exec-path (cons bin exec-path))) (apply orig args)))))
          (dolist (dir load-path)
            (dolist (mod (file-expand-wildcards (expand-file-name "jinx-mod*.so" dir)))
              (ignore-errors (misemacs--enchant-rpath-fix mod lib)))))))
    """
  end

  @doc "enchant.ordering making applespell the default backend (design §13, spike-C)."
  @spec ordering_contents() :: String.t()
  def ordering_contents, do: "*:applespell,hunspell\n"

  # IO runner (stage/3, verify/2) is added in Task 3.
  @doc false
  def __macho__, do: Macho
end
