defmodule Orchestrator.Terminfo do
  @moduledoc """
  Pure in-place rewrite of the terminfo path baked into bundled ncurses/tinfo.

  conda's libtinfo hard-codes `$CONDA_PREFIX/share/terminfo` as a `__cstring`, so no
  install-name rewrite reaches it; that dir is absent on user machines and `emacs -nw`
  fails with "Cannot open terminfo database file". IO is the caller's (`Relocate`).
  """

  @doc """
  Replace every NUL-terminated `needle` cstring in `bin` with `replacement`, NUL-padded to
  the original length so no Mach-O offsets shift. The trailing NUL must match: a needle
  that is only a prefix of a longer cstring is left alone, since padding would truncate it.
  """
  @spec patch(binary, String.t(), String.t()) ::
          {:ok, binary, pos_integer} | :unchanged | {:error, :replacement_too_long}
  def patch(bin, needle, replacement) do
    from = needle <> <<0>>
    pad = byte_size(from) - byte_size(replacement)

    if pad < 1 do
      {:error, :replacement_too_long}
    else
      case length(:binary.matches(bin, from)) do
        0 ->
          :unchanged

        n ->
          to = replacement <> :binary.copy(<<0>>, pad)
          {:ok, :binary.replace(bin, from, to, [:global]), n}
      end
    end
  end
end
