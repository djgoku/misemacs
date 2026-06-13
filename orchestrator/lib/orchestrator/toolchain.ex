defmodule Orchestrator.Toolchain do
  @moduledoc """
  IO behaviour for the macOS toolchain (CLT/SDK) fingerprint — Decision E (spec §8/§4.5).
  Folded into `Core.Hash.toolchain_hash/3` so a runner-image bump (new clang/SDK) triggers
  a rebuild. Captured identically by `mix orchestrate.decide` and the build cell's
  `mix release.manifest` (both on macos-26) so detect and the recorded fingerprint agree.
  """
  @callback clt_fingerprint() :: String.t()
end
