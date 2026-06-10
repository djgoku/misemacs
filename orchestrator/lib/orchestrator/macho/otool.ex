defmodule Orchestrator.Macho.Otool do
  @moduledoc "Default `Orchestrator.Macho.Tool` — shells host CLT tools, parses with `Orchestrator.Macho`."
  @behaviour Orchestrator.Macho.Tool
  alias Orchestrator.Macho

  @impl true
  def macho?(path) do
    File.regular?(path) and
      case System.cmd("file", ["-b", path], stderr_to_stdout: true) do
        {out, 0} -> String.contains?(out, "Mach-O")
        _ -> false
      end
  end

  @impl true
  def id(path), do: path |> run("otool", ["-D"]) |> Macho.parse_id()

  @impl true
  def deps(path), do: Macho.parse_deps(run(path, "otool", ["-L"]), id(path))

  @impl true
  def rpaths(path), do: path |> run("otool", ["-l"]) |> Macho.parse_rpaths()

  @impl true
  def set_id(path, new), do: int(path, ["-id", new])
  @impl true
  def change(path, old, new), do: int(path, ["-change", old, new])
  @impl true
  def add_rpath(path, rp), do: int_ok(path, ["-add_rpath", rp])
  @impl true
  def delete_rpath(path, rp), do: int_ok(path, ["-delete_rpath", rp])

  @impl true
  def resign(path) do
    System.cmd("codesign", ["--remove-signature", path], stderr_to_stdout: true)
    {_, 0} = System.cmd("codesign", ["-s", "-", "-f", path], stderr_to_stdout: true)
    :ok
  end

  defp run(path, cmd, args) do
    {out, _} = System.cmd(cmd, args ++ [path], stderr_to_stdout: true)
    out
  end

  defp int(path, args) do
    {_, 0} = System.cmd("install_name_tool", args ++ [path], stderr_to_stdout: true)
    :ok
  end

  defp int_ok(path, args) do
    System.cmd("install_name_tool", args ++ [path], stderr_to_stdout: true)
    :ok
  end
end
