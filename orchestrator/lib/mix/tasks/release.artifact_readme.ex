defmodule Mix.Tasks.Release.ArtifactReadme do
  @shortdoc "Print the channel-specific README.org for an artifact repo"
  @moduledoc """
  Renders the static, date-free `README.org` for a per-channel artifact repo
  (`<base>-emacs-<channel>`) to stdout. Keyed on `--version`; derives `channel` + upstream
  `ref` from `versions.toml` via `Orchestrator.Manifest.versions!/1`. Used as the artifact
  repo's bootstrap commit. Network-free.

      mix release.artifact_readme --version master [--artifact-base djgoku/misemacs] [--root ..]
  """
  use Mix.Task
  alias Orchestrator.{Manifest, Naming}

  @switches [version: :string, artifact_base: :string, root: :string]

  @impl true
  def run(argv) do
    # Force UTF-8 stdout so em-dashes/unicode in the README aren't emitted as literal
    # `\x{2014}` escapes when the runtime locale is latin1 (e.g. LC_ALL=C) and the output is
    # redirected to a file — the documented IO.puts/latin1 footgun.
    :io.setopts(:standard_io, encoding: :unicode)
    {opts, [], []} = OptionParser.parse(argv, strict: @switches)
    root = opts[:root] || ".."
    version = opts[:version] || Mix.raise("missing required --version")

    # Reuse the public version list (%{name, channel, ref}) instead of re-parsing versions.toml.
    v =
      Manifest.versions!(root)
      |> Enum.find(&(&1.name == version)) ||
        Mix.raise("no such version #{inspect(version)} in versions.toml")

    base = Naming.artifact_base(opts[:artifact_base])
    repo = Naming.artifact_repo(base, v.channel)

    IO.puts(
      render(%{
        channel: v.channel,
        ref: v.ref,
        base: base,
        repo: repo,
        upstream: Naming.upstream(v.upstream)
      })
    )
  end

  defp upstream_name(url), do: String.replace_prefix(url, "https://github.com/", "")

  defp render(%{channel: channel, ref: ref, base: base, repo: repo, upstream: upstream}) do
    """
    #+TITLE: misemacs — #{channel} channel (release artifacts)

    Auto-published release bucket for the =#{channel}= channel of
    [[https://github.com/#{base}][#{base}]] — a hermetically-built, relocatable =Emacs.app=
    for macOS (arm64), built from the =#{ref}= ref of
    [[#{upstream}][#{upstream_name(upstream)}]].

    *Nothing here is hand-edited.* Releases are produced by the daily pipeline in
    [[https://github.com/#{base}][#{base}]] and pushed here automatically.

    * Install (mise)

    Methods in order of preference.

    ** 1. aqua registry (zero-config) — coming soon

    Once this package is in the upstream aqua-registry, no setup is needed:

    #+begin_src sh
    mise use aqua:#{repo}@latest
    #+end_src

    (Not yet submitted upstream — use method 2 or 3 until then.)

    ** 2. Point mise at the misemacs registry (interim)

    #+begin_src sh
    MISE_AQUA_REGISTRIES=https://raw.githubusercontent.com/#{base}/main/aqua/registry.yaml \\
      mise use aqua:#{repo}@latest
    #+end_src

    Versions resolve as the bare date (=YYYY-MM-DD=); =@latest= rolls this channel forward.

    ** 3. GitHub backend (no registry config)

    #+begin_src sh
    mise use github:#{repo}@latest
    #+end_src

    Caveat: the =github:= backend uses the *full tag* as the version
    (=emacs-#{channel}-YYYY-MM-DD=), not the bare date.

    * What's in each release

    | asset | what it is |
    |-------+------------|
    | =misemacs-<tag>-macos-arm64.tar.gz= | the relocatable =Emacs.app= (with bundled enchant for spell-checking) |
    | =SHASUMS256.txt= | sha256 of the tarball, for manual verification |
    | =build-manifest.json= | records the upstream emacs commit + the build-input fingerprint for that release |

    * Verification

    mise verifies GitHub's per-asset digest automatically on both the aqua and =github:=
    install paths. To check by hand: download the tarball + =SHASUMS256.txt= and run
    =shasum -c SHASUMS256.txt=.

    * Versioning

    Tags are CalVer: =emacs-#{channel}-YYYY-MM-DD= (a =.N= suffix is added on same-day
    rebuilds). =@latest= rolls *this channel* independently and is marker-independent — the
    registry uses =version_source: github_tag=, so the newest tag wins, not GitHub's "Latest"
    badge.

    * Source & issues

    This is a generated artifact bucket — *do not open issues or pull requests here.*
    Source code, the build system, and documentation live in
    [[https://github.com/#{base}][#{base}]].
    """
  end
end
