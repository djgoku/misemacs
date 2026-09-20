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

    Each new release carries a signed =packslip.sigstore.json=. mise verifies the
    artifact repository's signing identity and the selected archive's digest.

    #+begin_src sh
    mise use packslip:github.com/#{repo}@latest
    # Or pin a published release:
    mise use packslip:github.com/#{repo}@YYYY.M.N
    #+end_src

    This requires a mise version with the Packslip backend. Existing releases from
    before the migration have no Packslip bundle; their tags and assets remain on
    GitHub for manual download. Install a new signed release through =packslip:=.
    mise's default 24-hour minimum release age can delay =@latest=; exact pins
    are available as soon as their Packslip has been signed.

    * Open it like an app

    Zero setup: every install puts =emacs-app= on your mise =PATH= — it launches the
    bundled =Emacs.app= through =open=, forwarding any args (fresh instance when args
    are given):

    #+begin_src sh
    emacs-app --init-directory ~/my-emacs-config --debug-init
    #+end_src

    For Finder / Dock / =open -a Emacs= integration: Packslip installs the app
    directly under the version directory and mise maintains a =latest= symlink
    per tool, so this path never moves across upgrades. Link it once:

    #+begin_src sh
    mkdir -p ~/Applications
    ln -sfn "$(dirname "$(mise where packslip:github.com/#{repo})")/latest/Emacs.app" ~/Applications/Emacs.app
    #+end_src

    Then =open ~/Applications/Emacs.app= / =open -a Emacs= work like any installed app,
    surviving every =mise up=.

    * What's in each release

    | asset | what it is |
    |-------+------------|
    | =misemacs-<tag>-macos-arm64.tar.gz= | the relocatable =Emacs.app= (with bundled enchant for spell-checking) |
    | =SHASUMS256.txt= | sha256 of the tarball, for manual verification |
    | =build-manifest.json= | records the upstream emacs commit + the build-input fingerprint for that release |
    | =packslip.sigstore.json= | signed artifact metadata, executable paths, and digests |

    * Verification

    mise verifies the signed Packslip and the downloaded archive automatically.
    For a manual check, download =packslip.sigstore.json= and the tarball, then run:

    #+begin_src sh
    packslip verify packslip.sigstore.json \\
      --identity-prefix https://github.com/#{repo}/ \\
      --issuer https://token.actions.githubusercontent.com \\
      --artifact misemacs-<tag>-macos-arm64.tar.gz
    #+end_src

    * Versioning

    New tags are SemVer-compatible CalVer: =vYYYY.M.N=, where =N= starts at 0
    each month and increments for every release, including same-day rebuilds.
    Each channel has its own repo, so =@latest= rolls that channel independently.

    * Source & issues

    This is a generated artifact bucket — *do not open issues or pull requests here.*
    Source code, the build system, and documentation live in
    [[https://github.com/#{base}][#{base}]].
    """
  end
end
