# inputs_hash.exs — print a stable sha256 of everything that determines a
# flavor's built Emacs.app (lockfiles + build.toml + mise.lock + build scripts).
# CI records this on each release and compares it next run to skip rebuilding
# an unchanged flavor. See Misemacs.Lib.inputs_hash/2 for the exact scheme.
#
# Usage: inputs_hash.exs <flavor>
Code.require_file("misemacs_lib.exs", __DIR__)

defmodule InputsHash do
  alias Misemacs.Lib

  def main([flavor]) when flavor != "" do
    root = Path.expand(Path.join(__DIR__, "../.."))
    IO.puts(Lib.inputs_hash(root, flavor))
  end

  def main(_), do: Misemacs.Lib.die("usage: inputs_hash.exs <flavor>")
end

InputsHash.main(System.argv())
