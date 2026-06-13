defmodule Orchestrator.Core.Hash do
  @moduledoc """
  Pure hashing for change detection. No IO.

  Fingerprint inputs are an ORDERED, NAMED list so a later IO caller cannot silently
  reorder or drop a field (which would mask a real change or trigger rebuild storms).
  Each entry is hashed as `label <NUL> bytes <NUL>`. Field `bytes` are assumed NUL-free
  (hex SHAs or text manifest files). Hash files to a hex digest first, then feed the
  DIGEST string into a fingerprint — never raw multi-record binary directly.
  """

  # The exact §8 fingerprint inputs, in the exact order. Freezing this is the point.
  @fingerprint_fields [:toolchain_hash, :upstream_sha, :mise_toml, :pixi_toml, :pixi_lock]

  @doc ~S(sha256 of iodata, as "sha256:" <> lowercase hex.)
  @spec hash(iodata()) :: String.t()
  def hash(iodata) do
    "sha256:" <> (:crypto.hash(:sha256, iodata) |> Base.encode16(case: :lower))
  end

  @doc "Toolchain hash = sha256 of mise.toml ⧺ mise.lock ⧺ CLT/SDK fingerprint (spec §8, Decision E)."
  @spec toolchain_hash(iodata(), iodata(), iodata()) :: String.t()
  def toolchain_hash(mise_toml, mise_lock, clt) do
    fingerprint([{"mise_toml", mise_toml}, {"mise_lock", mise_lock}, {"clt", clt}])
  end

  @doc """
  Hash an ordered, labeled list of `{label, bytes}` entries. Order and membership are
  part of the value — different order ⇒ different hash.
  """
  @spec fingerprint([{String.t(), iodata()}]) :: String.t()
  def fingerprint(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn {label, bytes} -> [label, <<0>>, bytes, <<0>>] end)
    |> hash()
  end

  @doc """
  Canonical per-version fingerprint over the fixed §8 field set, in the fixed order.
  `inputs` MUST contain every key in `fingerprint_fields/0`; a missing key raises
  (fail-loud), so a caller cannot accidentally drop an input.
  """
  @spec version_fingerprint(map()) :: String.t()
  def version_fingerprint(inputs) do
    @fingerprint_fields
    |> Enum.map(fn field -> {Atom.to_string(field), Map.fetch!(inputs, field)} end)
    |> fingerprint()
  end

  @doc "The frozen fingerprint field order (for tests / callers)."
  @spec fingerprint_fields() :: [atom()]
  def fingerprint_fields, do: @fingerprint_fields
end
