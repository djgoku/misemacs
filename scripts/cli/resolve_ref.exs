# resolve_ref.exs — resolve a remote ref to a single commit sha via
# `git ls-remote`, erroring if the ref is missing or ambiguous.
#
# Usage: resolve_ref.exs <repo-url> <ref>
Code.require_file("misemacs_lib.exs", __DIR__)

defmodule ResolveRef do
  alias Misemacs.Lib

  def main([repo, ref]) when repo != "" and ref != "" do
    case Lib.parse_ls_remote(Lib.sh("git", ["ls-remote", repo, ref])) do
      {:ok, sha} -> IO.puts(sha)
      {:error, :none} -> Lib.die("resolve-ref: ref '#{ref}' not found on #{repo}")
      {:error, :ambiguous} -> Lib.die("resolve-ref: ref '#{ref}' is ambiguous on #{repo}")
    end
  end

  def main(_), do: Misemacs.Lib.die("usage: resolve_ref.exs <repo-url> <ref>")
end

ResolveRef.main(System.argv())
