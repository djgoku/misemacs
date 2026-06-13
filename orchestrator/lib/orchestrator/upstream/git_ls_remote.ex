defmodule Orchestrator.Upstream.GitLsRemote do
  @moduledoc "Default `Orchestrator.Upstream` — `git ls-remote https://github.com/emacsmirror/emacs <ref>`."
  @behaviour Orchestrator.Upstream
  @url "https://github.com/emacsmirror/emacs"

  @impl true
  def resolve(ref) do
    case System.cmd("git", ["ls-remote", @url, ref], stderr_to_stdout: true) do
      {out, 0} -> parse(out, ref)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc "Pure: pick the sha for `ref` from ls-remote stdout (`<sha>\\t<refname>` lines); nil if none."
  @spec parse(String.t(), String.t()) :: String.t() | nil
  def parse(out, ref) do
    rows =
      out
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "\t", parts: 2) do
          [sha, name] -> [{String.trim(sha), name}]
          _ -> []
        end
      end)

    exact = Enum.find(rows, fn {_, n} -> n in ["refs/heads/#{ref}", "refs/tags/#{ref}"] end)

    case exact || List.first(rows) do
      {sha, _} -> sha
      nil -> nil
    end
  end
end
