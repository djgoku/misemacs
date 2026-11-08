# Report-only: lists available updates, never writes a manifest or lock.
# Each check returns {:ok, rows} with one %{name, current, latest} per outdated item
# (current is nil for a package an upgrade would newly add), or {:error, message}.
defmodule Outdated do
  def main do
    File.cd!(Path.expand("..", __DIR__))

    results =
      checks()
      |> Task.async_stream(fn {title, check} -> {title, check.()} end,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    Enum.each(results, &render/1)
    if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: System.halt(1)
  end

  defp checks do
    pixi =
      for manifest <- Path.wildcard("versions/*/pixi.toml") do
        {"pixi: #{manifest} (past its version ranges)", fn -> pixi(manifest) end}
      end

    [{"mise tools (newest release overall)", &mise/0}] ++
      pixi ++
      [
        {"pixi git sources (locked commit vs branch head)", &git_sources/0},
        {"GitHub Actions (Pkl-pinned tag vs latest release)", &actions/0}
      ]
  end

  defp mise do
    with {:ok, json} <- cmd("mise", ~w(outdated --bump --no-global --json)) do
      {:ok, for({name, t} <- JSON.decode!(json), do: row(name, t["current"], t["latest"]))}
    end
  end

  # `upgrade` looks past the manifest's version ranges; `update` would only re-solve within them.
  defp pixi(manifest) do
    with {:ok, json} <- cmd("pixi", ~w(upgrade --dry-run --no-install --json -m) ++ [manifest]) do
      rows =
        for {_env, platforms} <- JSON.decode!(json)["environment"] || %{},
            {_platform, pkgs} <- platforms,
            pkg <- pkgs,
            do: row(pkg["name"], conda_version(pkg["name"], pkg["before"]), conda_version(pkg["name"], pkg["after"]))

      {:ok, Enum.uniq(rows)}
    end
  end

  # pixi's JSON carries no version field, only the package URL: <name>-<version>-<build>.conda
  defp conda_version(_name, nil), do: nil

  defp conda_version(name, %{"conda" => url}) do
    url |> Path.basename() |> String.replace_prefix(name <> "-", "") |> String.split("-") |> hd()
  end

  defp git_sources do
    Path.wildcard("versions/*/pixi.lock")
    |> Enum.flat_map(&Regex.scan(~r{git\+(https://[^?\s]+)\?[^#\s]*branch=([^&#\s]+)[^#\s]*#([0-9a-f]+)}, File.read!(&1)))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn [_, url, branch, locked], {:ok, rows} ->
      case cmd("git", ["ls-remote", url, "refs/heads/#{branch}"]) do
        {:ok, out} ->
          head = out |> String.split() |> List.first("")
          {:cont, {:ok, rows ++ outdated(row("#{url}@#{branch}", short(locked), short(head)))}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp actions do
    Path.wildcard(".github/**/*.pkl")
    |> Enum.flat_map(&Regex.scan(~r/uses = "([^"@]+)@([^"]+)"/, File.read!(&1)))
    |> Enum.uniq()
    |> Task.async_stream(fn [_, repo, pinned] ->
      with {:ok, out} <- cmd("gh", ["api", "repos/#{repo}/releases/latest", "--jq", ".tag_name"]) do
        latest = String.trim(out)
        # A floating major pin like v4 is current when the latest release is v4.x.y.
        current? = latest == pinned or String.starts_with?(latest, pinned <> ".")
        {:ok, if(current?, do: [], else: [row(repo, pinned, latest)])}
      end
    end)
    |> Enum.reduce({:ok, []}, fn
      {:ok, {:ok, rows}}, {:ok, acc} -> {:ok, acc ++ rows}
      {:ok, {:error, _} = error}, _ -> error
      _, error -> error
    end)
  end

  defp row(name, current, latest), do: %{name: name, current: current, latest: latest}
  defp outdated(%{current: same, latest: same}), do: []
  defp outdated(row), do: [row]
  defp short(sha), do: String.slice(sha, 0, 12)

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "#{bin} #{Enum.join(args, " ")} exited #{status}\n#{out}"}
    end
  end

  defp render({title, result}) do
    IO.puts("\n== #{title}")

    case result do
      {:ok, []} ->
        IO.puts("up to date")

      {:ok, rows} ->
        width = rows |> Enum.map(&String.length(&1.name)) |> Enum.max()

        for %{name: name, current: current, latest: latest} <- rows do
          IO.puts("#{String.pad_trailing(name, width)}  #{current || "(new)"} -> #{latest}")
        end

      {:error, message} ->
        IO.puts("FAILED: #{String.trim(message)}")
    end
  end
end

Outdated.main()
