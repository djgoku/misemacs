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
  def sign_bundle(app) do
    {_, 0} =
      System.cmd("codesign", ["--force", "--deep", "--sign", "-", app], stderr_to_stdout: true)

    :ok
  end

  @impl true
  def verify_bundle(app) do
    case System.cmd("codesign", ["--verify", "--deep", "--strict", app], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @impl true
  def sign_file(path) do
    {_, 0} = System.cmd("codesign", ["--force", "--sign", "-", path], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def verify_file(path) do
    case System.cmd("codesign", ["--verify", "--strict", path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp run(path, cmd, args) do
    {out, _} = System.cmd(cmd, args ++ [path], stderr_to_stdout: true)
    out
  end

  defp int(path, args) do
    {_, 0} = System.cmd("install_name_tool", args ++ [path], stderr_to_stdout: true)
    :ok
  end

  # tolerate nonzero: re-runs hit benign "would duplicate rpath" / "no such rpath" — required for idempotency
  defp int_ok(path, args) do
    System.cmd("install_name_tool", args ++ [path], stderr_to_stdout: true)
    :ok
  end
end
