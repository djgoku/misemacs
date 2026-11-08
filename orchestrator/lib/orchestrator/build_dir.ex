defmodule Orchestrator.BuildDir do
  @moduledoc """
  The `build/<version>/` outputs of `mise run build` that later stages consume: the built
  `Emacs.app` and `conda-prefix-lib.txt`, whose content is the pixi env's `<conda_prefix>/lib`.
  """

  @enforce_keys [:app, :conda_lib]
  defstruct [:app, :conda_lib]

  @type t :: %__MODULE__{app: Path.t(), conda_lib: Path.t()}

  @spec load(Path.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(root, version) do
    dir = Path.join([root, "build", version])
    app = Path.join(dir, "Emacs.app")
    lib_file = Path.join(dir, "conda-prefix-lib.txt")

    cond do
      not File.dir?(app) ->
        {:error, "#{app} missing; run 'mise run build #{version}' first"}

      not File.regular?(lib_file) ->
        {:error, "#{lib_file} missing; run 'mise run build #{version}' first"}

      true ->
        {:ok, %__MODULE__{app: app, conda_lib: lib_file |> File.read!() |> String.trim()}}
    end
  end

  @spec conda_prefix(t()) :: Path.t()
  def conda_prefix(%__MODULE__{conda_lib: lib}), do: Path.dirname(lib)
end
