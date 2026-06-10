defmodule Orchestrator.Macho.Tool do
  @moduledoc "IO behaviour for Mach-O introspection + mutation (otool/install_name_tool/codesign)."
  @callback macho?(Path.t()) :: boolean
  @callback id(Path.t()) :: String.t() | nil
  @callback deps(Path.t()) :: [String.t()]
  @callback rpaths(Path.t()) :: [String.t()]
  @callback set_id(Path.t(), String.t()) :: :ok
  @callback change(Path.t(), String.t(), String.t()) :: :ok
  @callback add_rpath(Path.t(), String.t()) :: :ok
  @callback delete_rpath(Path.t(), String.t()) :: :ok
  @callback resign(Path.t()) :: :ok
end
