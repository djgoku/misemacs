defmodule Orchestrator.Toolchain.Macos do
  @moduledoc """
  Default `Orchestrator.Toolchain` — the STABLE macOS CLT/SDK identity: `xcode-select -p`,
  the `Apple clang version …(clang-<build>)` line of `clang --version` (the host-OS-volatile
  `Target:`/`InstalledDir`/`Thread model` lines dropped), and `xcrun --show-sdk-version`.
  Reasoning (`normalize/3`) is pure; only `clt_fingerprint/0` shells out.
  """
  @behaviour Orchestrator.Toolchain
  alias Orchestrator.Core.Hash

  @impl true
  def clt_fingerprint do
    normalize(
      cmd("xcode-select", ["-p"]),
      cmd("clang", ["--version"]),
      cmd("xcrun", ["--show-sdk-version"])
    )
  end

  @doc "Pure: the three command outputs → a stable `sha256:` fingerprint."
  @spec normalize(String.t(), String.t(), String.t()) :: String.t()
  def normalize(xcode_path, clang_version, sdk_version) do
    Hash.fingerprint([
      {"xcode_select", String.trim(xcode_path)},
      {"clang", clang_line(clang_version)},
      {"sdk", String.trim(sdk_version)}
    ])
  end

  defp clang_line(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find("", &String.starts_with?(&1, "Apple clang version "))
    |> String.trim()
  end

  defp cmd(bin, args) do
    {out, 0} = System.cmd(bin, args, stderr_to_stdout: true)
    out
  end
end
