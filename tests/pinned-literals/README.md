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

`#158` widened the check past this one pin, in two directions — read the rest of this file for the
original `xunit.v3` classification, still accurate for that pin, then see below for what changed:

- **A second DERIVED pin** — `COVERAGE_EXT_VERSION` (`Microsoft.Testing.Extensions.CodeCoverage`),
  marker `pinned:coverage-ext`, one more row in `PINS`, same "marked / historical / refuse" rule as
  `xunit.v3`'s. Its own canonical marked claim lives at `tests/xunit-v3/apply-transform.py`, right
  next to `COVERAGE_EXT_VERSION`'s definition; the existing measurement banners in
  `templates/ci-dotnet.yml` and `tests/xunit-v3/test.sh` spell the package by its short alias
  ("CodeCoverage", not the full id `claim_patterns()` anchors on) and are recorded HISTORICAL
  instead, rather than widening that shared pattern for one package's alias.
- **A third KIND, AGREED**, for a literal with **no constant to derive from** — `samples/LegacyShop`
  is a frozen fixture, and nothing may derive FROM it. Three AGREED pins
  (`frozen-xunit-core` / `frozen-xunit-runner` / `frozen-test-sdk`, package `xunit` /
  `xunit.runner.visualstudio` / `Microsoft.NET.Test.Sdk`) hold that fixture's two in-repo
  restatements — `renovate.json`'s description of the frozen fixture, and the scratch v2 csproj
  `tests/xunit-v3/test.sh` builds to mirror it — to **each other**: every marked occurrence must
  state the same value, or the check refuses naming every value seen; fewer than two marked
  occurrences refuses too (an agreement of one is vacuous). AGREED has no literal-scan half — with
  no authority there is no "the version" to hunt unmarked spellings of, so it sees only what is
  explicitly marked, **plus one `witness`**: `samples/LegacyShop`'s own real csproj, read directly
  for a third occurrence since a frozen file can never carry a marker of its own. Without it the two
  restatements could agree with each other while both had drifted from the fixture they restate, and
  the check would still accept — code review on #158 caught that gap; the witness closes it. See
  `scripts/pinned-literals-check.py`'s own `Pin`/`check_pin_agreed` docstrings for the mechanism.

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

Applied below, that rule alone classifies 6 of the 8 historical entries; the other two are the
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
| `tests/xunit-v3/test.sh:237` | section 3: the `OutputType` guard, measured on the pinned package |
| `tests/xunit-v3/test.sh:473` | section 4f: the `--coverage`-refusal measurement |
| `tests/xunit-v3/test.sh:904` | section 7's keyed-on-the-id argument, `xunit.v3` half |

Two of these are new coverage relative to `[7e]`, which read only `apply-transform.py` and the
migration reference: `templates/ci-dotnet.yml` — the file this kit *ships* — and the three claims
inside `tests/xunit-v3/test.sh` itself.

`tests/xunit-v3/test.sh:237` needed a one-line reflow to become checkable: the claim was wrapped
across two comment lines, with the package id ending one and the version starting the next. A claim
a reader can see and a checker cannot is the failure mode this issue is about, so the comment was
rewrapped rather than excused.

### historical — recorded, must not move (8)

Each of these is an entry in `HISTORICAL` inside `scripts/pinned-literals-check.py`, carrying the
reason below. An entry must match **exactly one** line: an anchor broad enough to cover two would
swallow the next copy silently, which is the exclusion-list failure this design rejects.

| file:line | why it must not track the pin |
|---|---|
| `skills/legacy-upgrade/references/xunit-v3-migration.md:136` | the measured table's **`mtp-v2`** row — the other MTP line (`MTP_LINE` → 2) |
| `skills/legacy-upgrade/references/xunit-v3-migration.md:153` | the "`mtp-v2` 3.2.x are stable" enumeration — the evidence that the major does not pick the line |
| `tests/xunit-v3/apply-transform.py:42` | the header table's **`mtp-v2`** row — same reason as the reference's |
| `tests/xunit-v3/apply-transform.py:44` | the same stable-releases enumeration, in the module |
| `tests/xunit-v3/apply-transform.py:65` | a measurement of `xunit.v3.core.mtp-v{1,2}`'s nuspecs — it spans **both** lines, so the v2 leg is not this pin's to govern; re-measure both legs by hand when the pin moves |
| `tests/xunit-v3/apply-transform.py:149` | an *illustration* of a wrong-answer message (a version string landing in the package-id slot). The point is the slot, not the number |
| `tests/xunit-v3/test.sh:613` | ⚠️ **the scratch `.csproj` fixture — an INPUT to the transform.** Derive it from the constant and the test starts asserting against a value it generated itself, so it would stop detecting the drift it exists to catch |
| `tests/xunit-v3/test.sh:905` | section 7's `mtp-v2` half — the other MTP line |

### neither — the source itself

`tests/xunit-v3/apply-transform.py:54` is `XUNIT_V3_VERSION`'s own definition. The check skips that
one line rather than listing it: it is what every other spelling is compared against, not a copy of
it.

### deliberately out of scope

- **The rest of the `Microsoft.Testing.*` family** beyond `CodeCoverage` (`Platform`,
  `Extensions.Telemetry`, `Extensions.TrxReport.Abstractions`, …). `#158` covers the two legs
  Renovate bumps (`xunit.v3`, `CodeCoverage`); the rest move AS the platform line rather than
  carrying their own independent version, so there is no separate literal to pin yet.
- **Generating** `templates/ci-dotnet.yml` or the scratch fixtures from a constant (`#90` brainstorm
  D, revisited and still rejected by `#158`): the template ships verbatim and has no generation
  step, and the fixtures are inputs — `samples/LegacyShop` most of all, since it is frozen and
  nothing may derive FROM it (which is the whole reason `#158` needed a THIRD kind, AGREED, above).
- **`repo-audit/net10_blacklist.json`**, the portfolio-side third restatement `renovate.json` used
  to name. It is not reachable from this repo's scan root, so the AGREED trio covers the two
  in-repo files only — `#158`'s issue says so rather than pretending to cover three.

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
