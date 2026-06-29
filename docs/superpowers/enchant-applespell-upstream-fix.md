# enchant AppleSpell provider — use-after-free in `request_dict` (upstream fix handoff)

*Found + fixed 2026-06-28 while bundling enchant into misemacs `Emacs.app`. This is an **upstream
enchant** bug (present in enchant 2.8.2 stock source `providers/applespell_checker.mm`), not a
misemacs or feedstock-recipe defect. Hand this to the feedstock branch
(`djgoku/enchant-feedstock@misemacs-recipe`) and/or upstream [AbiWord/enchant](https://github.com/AbiWord/enchant).*

Patch: [`patches/applespell-request-dict-uaf.patch`](patches/applespell-request-dict-uaf.patch)

## Symptom

`enchant-2 -l -d en` (a bare 2-letter language tag with no region) **flakily segfaults**. Reproduced
on macOS arm64 with enchant 2.8.2 (AppleSpell default ordering): **29 / 40 runs crashed**; the rest
exited cleanly — the hallmark of a heap-state-dependent memory bug. Region tags (`en_US`, `en_GB`, …)
do **not** crash because AppleSpell maps them, so the failing path below is never taken.

In a bundled context the crash also surfaced for `-d en_US` whenever the AppleSpell locale map
(`share/enchant-2/AppleSpell.config`) was missing: with no locale claimed, enchant falls back from
`en_US` to the bare `en` tag and hits this same bug. (misemacs fixes that trigger separately by always
staging `AppleSpell.config`; this patch fixes the underlying crash.)

## Backtrace

```
EXC_BAD_ACCESS (code=1, address=0x60)
#0 enchant_dict_finalize + 24            (x0 = NULL, ldr x8, [x0, #0x60])
#1 enchant_dict_unref + 48
#2 enchant_broker_new_dict + 64
#3 enchant_applespell.so`appleSpell_provider_request_dict(tag="en") at applespell_checker.mm:304
#4 _enchant_broker_request_dict
#5 enchant_broker_request_dict_with_pwl
#6 main
```

## Root cause

`appleSpell_provider_request_dict` calls `enchant_broker_new_dict(me->owner)` **first** —
which allocates an `EnchantDict` *and registers it in the broker's `dicts` hash table* (the broker
holds a ref) — and only **afterwards** asks AppleSpell whether it can serve the tag
(`checker->requestDictionary(tag)`). When AppleSpell cannot map the tag, the function bails out with
`g_free(dict)`.

That is wrong two ways:

1. `dict` is a ref-counted `EnchantDict` (GObject-style), not a plain `g_malloc` block — it must not be
   `g_free`d.
2. It is still **registered in the broker's `dicts` hash table**, so `g_free`ing the raw pointer leaves
   a freed, dangling, still-referenced entry there. A later broker operation (or even the unref that
   `enchant_broker_new_dict` itself performs) then dereferences/finalizes that garbage → the NULL-ish
   deref in `enchant_dict_finalize`. Heap-reuse timing makes it flaky.

Every other provider does it the right way round — they resolve the dictionary **first** and call
`enchant_broker_new_dict` **only on success**, so there is no post-`new_dict` failure path and nothing
is ever freed by hand:

- `enchant_hunspell.cpp` → `if (!checker->requestDictionary(tag)) { …; return NULL; } EnchantDict *dict = enchant_broker_new_dict(me->owner); …`
- `enchant_aspell.c`, `enchant_nuspell.cpp`, `enchant_hspell.c`, `enchant_voikko.c`, `enchant_zemberek.cpp` — same shape.

## The fix

Reorder `appleSpell_provider_request_dict` to match the other providers: validate args, resolve the
AppleSpell language up front, and create the dict **only once success is guaranteed**. Remove the
`g_free(dict)` failure paths entirely (the one remaining `new_dict`-returned-NULL guard cleans up only
the provider-owned `ASD` + the retained `NSString`, never the dict). See the patch file.

## Verified

Recompiled just the patched provider and swapped it into a built enchant on macOS arm64:

| provider | `-d en` (×40) | `-d en_US` |
|---|---|---|
| stock | **29/40 crash** | works |
| patched | **0/40 crash** | works + suggests (`hello, he'll`) |

## How to apply

**Upstream / source tree** (stock enchant 2.8.2; the file is unchanged on enchant `master` at the time
of writing — re-confirm before opening a PR):

```sh
cd enchant
git apply path/to/applespell-request-dict-uaf.patch   # paths are a/providers/… b/providers/…
```

**In the feedstock recipe** (`djgoku/enchant-feedstock@misemacs-recipe`): drop the `.patch` into the
recipe's patch set and add it to the rattler-build `source.patches:` list (next to the existing
`dladdr` self-relocation patch), so every build carries the fix. Once enchant builds with this patch,
the bare-`en` AppleSpell crash is gone and the `AppleSpell.config` staging in misemacs becomes the only
remaining requirement for the default backend.
