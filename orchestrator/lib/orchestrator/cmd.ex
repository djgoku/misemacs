defmodule Orchestrator.Cmd do
  @moduledoc "External commands for the release pipeline tasks. Failures raise `Mix.Error`."

  @doc "Run with output streamed to the terminal."
  @spec run!(String.t(), [String.t()], keyword()) :: :ok
  def run!(cmd, args, opts \\ []) do
    case exec(cmd, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{cmd} #{Enum.join(args, " ")} exited #{status}")
    end
  end

  @doc "Run and return stdout; stderr goes to the terminal."
  @spec out!(String.t(), [String.t()], keyword()) :: String.t()
  def out!(cmd, args, opts \\ []) do
    case exec(cmd, args, opts) do
      {out, 0} -> out
      {_, status} -> Mix.raise("#{cmd} #{Enum.join(args, " ")} exited #{status}")
    end
  end

  @doc "Run and return `{stdout_and_stderr, status}` without raising."
  @spec capture(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def capture(cmd, args, opts \\ []), do: exec(cmd, args, [stderr_to_stdout: true] ++ opts)

  defp exec(cmd, args, opts) do
    case System.find_executable(cmd) do
      nil -> Mix.raise("#{cmd} not found on PATH")
      path -> System.cmd(path, args, opts)
    end
  end
end
