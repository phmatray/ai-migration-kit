# The pinned `xunit.v3` version: where it is spelled, and which spellings must move

`XUNIT_V3_VERSION` in `tests/xunit-v3/apply-transform.py` is the constant Renovate bumps (`#36`).
`tests/xunit-v3/test.sh` `[7e]` (`#69`) already asserts that the *measurement claims* in that module
and in `skills/legacy-upgrade/references/xunit-v3-migration.md` agree with it. It stopped there on
purpose, and `#90` is the question it left open: **the same literal appears in a dozen more lines,
and they are not all the same kind of thing.**

This file is the classification the check in `scripts/pinned-literals-check.py` enforces. It is
written so that it does **not itself spell the version** — every occurrence below is named by
`file:line` and by what it claims, never by quoting the number. A classification document that
carried its own copy of the pin would be one more place to forget.

## The two kinds

| kind | meaning | mechanism |
|---|---|---|
| **pinned** | a *derived fact*: the claim is about `XUNIT_V3_PACKAGE`, so it must equal `XUNIT_V3_VERSION` | an inline `pinned:xunit-v3` marker on the line |
| **historical** | a *record*: the claim is deliberately not governed by the pin and must not move | an entry in `HISTORICAL` inside the check, with its reason |

Anything that is **neither** is refused, naming `file:line`. That asymmetry is the whole design
(`#90`, approach B): a new copy of the pin must **fail loudly**, never be quietly swept into
agreement. An exclusion list would have inverted it.

> **Never rewrite a historical entry to agree with the constant.** The `mtp-v2` enumerations exist
> precisely to show that the *major does not determine the MTP line* — which is what `MTP_LINE`
> encodes. "Fixing" them destroys the distinction.

## Confirming the classification against `MTP_LINE`

`MTP_LINE` maps a package **id** to the Microsoft.Testing.Platform major line it binds to:
`xunit.v3` → 1, `xunit.v3.mtp-v2` → 2. That map is the rule this classification is checked against,
and it settles every ambiguous line mechanically:

**An occurrence describing the `mtp-v2` line — or any package other than `XUNIT_V3_PACKAGE` — is
historical by construction.** Its version is a *measurement of a different package*, on the other
side of the v1/v2 boundary, and nothing about the `xunit.v3` pin governs it. Forcing it to track
`XUNIT_V3_VERSION` would encode exactly the "the major determines the line" mistake `MTP_LINE`
exists to refuse.

Applied below, that rule alone classifies 7 of the 9 historical entries; the other two are the
transform's *input* fixture and an illustration of a wrong-answer message.

## The inventory

Line numbers are as of this change; the check is the live authority, and it names `file:line` in
every refusal.

### pinned — must equal the constant (8)

| file:line | what it claims |
|---|---|
| `renovate.json:78` | prose: which MTP major the pinned package resolves to |
| `skills/legacy-upgrade/references/xunit-v3-migration.md:65` | the `OutputType` trap, measured on the pinned package |
| `skills/legacy-upgrade/references/xunit-v3-migration.md:135` | the measured-resolution table's `xunit.v3` row |
| `templates/ci-dotnet.yml:89` | the coverage guard's measurement banner — **shipped to migrated repos** |
| `tests/xunit-v3/apply-transform.py:41` | the module header's resolution table, `xunit.v3` row |
| `tests/xunit-v3/test.sh:236` | section 3: the `OutputType` guard, measured on the pinned package |
| `tests/xunit-v3/test.sh:468` | section 4f: the `--coverage`-refusal measurement |
| `tests/xunit-v3/test.sh:899` | section 7's keyed-on-the-id argument, `xunit.v3` half |

Two of these are new coverage relative to `[7e]`, which read only `apply-transform.py` and the
migration reference: `templates/ci-dotnet.yml` — the file this kit *ships* — and the three claims
inside `tests/xunit-v3/test.sh` itself.

`tests/xunit-v3/test.sh:236` needed a one-line reflow to become checkable: the claim was wrapped
across two comment lines, with the package id ending one and the version starting the next. A claim
a reader can see and a checker cannot is the failure mode this issue is about, so the comment was
rewrapped rather than excused.

### historical — recorded, must not move (9)

| file:line | why it must not track the pin |
|---|---|
| `skills/legacy-upgrade/references/xunit-v3-migration.md:136` | the measured table's **`mtp-v2`** row — the other MTP line (`MTP_LINE` → 2) |
| `skills/legacy-upgrade/references/xunit-v3-migration.md:153` | the "`mtp-v2` 3.2.x are stable" enumeration — the evidence that the major does not pick the line |
| `tests/xunit-v3/apply-transform.py:42` | the header table's **`mtp-v2`** row — same reason as the reference's |
| `tests/xunit-v3/apply-transform.py:44` | the same stable-releases enumeration, in the module |
| `tests/xunit-v3/apply-transform.py:65` | a measurement of `xunit.v3.core.mtp-v{1,2}`'s nuspecs — it spans **both** lines, so the v2 leg is not this pin's to govern; re-measure both legs by hand when the pin moves |
| `tests/xunit-v3/apply-transform.py:149` | an *illustration* of a wrong-answer message (a version string landing in the package-id slot). The point is the slot, not the number |
| `tests/xunit-v3/test.sh:608` | ⚠️ **the scratch `.csproj` fixture — an INPUT to the transform.** Derive it from the constant and the test starts asserting against a value it generated itself, so it would stop detecting the drift it exists to catch |
| `tests/xunit-v3/test.sh:900` | section 7's `mtp-v2` half — the other MTP line |
| `tests/xunit-v3/apply-transform.py:54` | the constant's **own definition**, skipped by the check rather than listed: it is the source every other spelling is compared against |

### deliberately out of scope

- **`COVERAGE_EXT_VERSION`** and the rest of the `Microsoft.Testing.*` family. `#90` scopes this
  pass to `xunit.v3`, the leg Renovate bumps most visibly. Extending the check is one more entry in
  its `PINS` table, not a redesign.
- **Generating** `templates/ci-dotnet.yml` or the scratch fixtures from the constant (`#90`
  brainstorm D): the template ships verbatim and has no generation step, and the fixtures are
  inputs.

## The marker convention

The marker is the bare token `pinned:xunit-v3`, placed anywhere on the line that carries the claim,
in whatever comment syntax the file uses:

| file type | spelling |
|---|---|
| Python, YAML, shell | `  # pinned:xunit-v3` appended to the line |
| Markdown | `<!-- pinned:xunit-v3 -->` (inside the last table cell on a table row, so the row's shape is unchanged) |
| JSON | inside the string itself — `renovate.json` has no comment syntax, so the marker reads as `(pinned:xunit-v3)` in the prose |

A marked line must contain at least one claim of the form `<XUNIT_V3_PACKAGE> <version>`, and every
such claim on it must equal the constant. That is why marking is not circular: the check finds the
line **by its marker**, then demands the current version — so the day Renovate bumps the pin, every
marked line that still spells the old one is refused by `file:line`.

The refusal never says "edit the number". These are **measurements**, resolved through
`api.nuget.org/v3-flatcontainer`, and substituting whatever Renovate last bumped to would
manufacture a measurement nobody took — worse than a stale one, because it looks current. `[7e]`
made that argument first; the check repeats it verbatim in its message.
