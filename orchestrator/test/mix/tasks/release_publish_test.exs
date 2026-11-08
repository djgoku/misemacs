defmodule Mix.Tasks.Release.PublishTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Release.{Package, Publish}

  test "ls_remote_tags strips refs/tags/ and folds peeled duplicates" do
    out = """
    aaa\trefs/tags/v2026.9.0
    bbb\trefs/tags/v2026.9.0^{}
    ccc\trefs/tags/v2026.9.1
    ddd\trefs/heads/main
    """

    assert Publish.ls_remote_tags(out) == ["v2026.9.0", "v2026.9.1"]
  end

  test "git_blob_sha matches git hash-object for the Packslip workflow template" do
    path = Path.expand("../../../../templates/artifact-packslip.yml", __DIR__)
    {expected, 0} = System.cmd("git", ["hash-object", path])
    assert Publish.git_blob_sha(File.read!(path)) == String.trim(expected)
  end

  test "check_listing wants every entry under the stable dir and every binary present" do
    bins = ["Emacs.app/Contents/MacOS/Emacs", "Emacs.app/Contents/MacOS/bin/emacs-cli"]
    listing = ["misemacs/", "misemacs/Emacs.app/" | Enum.map(bins, &"misemacs/#{&1}")]

    assert Package.check_listing(listing, "misemacs", bins) == :ok

    assert Package.check_listing(["stray" | listing], "misemacs", bins) ==
             {:error, "entry outside stable dir: stray"}

    assert Package.check_listing(Enum.drop(listing, -1), "misemacs", bins) ==
             {:error, "Emacs.app/Contents/MacOS/bin/emacs-cli missing from tarball"}
  end
end
