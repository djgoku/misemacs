defmodule Orchestrator.Core.Tag do
  @moduledoc """
  Pure tag computation. No IO. Packslip discovers a release from its SemVer tag.
  The patch is a monthly counter, starting at zero and incrementing for every
  release in that channel's repository. It resets when the month changes.

  RETRY-ON-CONFLICT CONTRACT (Phase 5): `next_tag/3` is pure over a tag SNAPSHOT. The
  publisher MUST pass a freshly-fetched `existing_tags` on EACH publish attempt; on a
  `gh release create` tag collision, re-fetch the tag list and recompute — never reuse a
  previously-computed tag.
  """
  alias Orchestrator.Naming

  @spec next_tag(String.t(), String.t(), [String.t()]) :: String.t()
  def next_tag(channel, date, existing_tags) do
    base = Naming.tag_base(channel, date)

    [year, month, _first_counter] =
      base |> String.trim_leading("v") |> String.split(".") |> Enum.map(&String.to_integer/1)

    used =
      existing_tags
      |> Enum.flat_map(fn tag ->
        case Regex.run(~r/^v(\d+)\.(\d+)\.(\d+)$/, tag, capture: :all_but_first) do
          [y, m, p] ->
            {y, m, p} = {String.to_integer(y), String.to_integer(m), String.to_integer(p)}
            if y == year and m == month, do: [p], else: []

          _ ->
            []
        end
      end)

    next = if used == [], do: 0, else: Enum.max(used) + 1
    "v#{year}.#{month}.#{next}"
  end
end
