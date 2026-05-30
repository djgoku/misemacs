# compute_version.exs — emit `VERSION=<flavor>-<calver>` to stdout.
#
#   argv[0]                       flavor (required), e.g. emacs-master.
#   argv[1] (or $VERSION_INPUT)   explicit calver, validated YYYY.MM.DD[.N].
#   no calver                     today (UTC); if <flavor>-<calver> tag exists,
#                                 append .1, .2, … to the first free tag.
#
# Reads LOCAL tags (`git tag --list`). Precondition: tags must be fetched
# (CI checkout uses fetch-depth: 0, which fetches tags).
Code.require_file("misemacs_lib.exs", __DIR__)

defmodule ComputeVersion do
  alias Misemacs.Lib

  def main(argv) do
    {flavor, input} = parse(argv)

    version =
      cond do
        input != "" and not Lib.valid_calver?(input) ->
          Lib.die("compute-version: invalid calver '#{input}' (expected YYYY.MM.DD or YYYY.MM.DD.N)")

        input != "" ->
          input

        true ->
          Lib.next_calver(today_utc(), existing_calvers(flavor))
      end

    IO.puts("VERSION=#{flavor}-#{version}")
  end

  defp parse([flavor | rest]) when flavor != "" do
    input =
      case rest do
        [v | _] -> v
        [] -> System.get_env("VERSION_INPUT", "")
      end

    {flavor, input}
  end

  defp parse(_), do: Misemacs.Lib.die("compute-version: missing flavor argument")

  defp today_utc do
    d = Date.utc_today()
    "#{d.year}.#{pad(d.month)}.#{pad(d.day)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp existing_calvers(flavor) do
    prefix = flavor <> "-"

    Misemacs.Lib.sh("git", ["tag", "--list", prefix <> "*"])
    |> String.split("\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> MapSet.new()
  end
end

ComputeVersion.main(System.argv())
