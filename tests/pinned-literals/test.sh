#!/usr/bin/env bash
# Golden test for scripts/pinned-literals-check.py — the guard that every spelling of the pinned
# xunit.v3 version is either MARKED as derived from the constant, or RECORDED as historical (#90).
#
# What this suite guards:
#   0. the baseline fixture is genuinely accounted for   -> accept (every mutation below is of it)
#   1. a new copy, neither marked nor recorded           -> REFUSE, naming file:line
#   2. a marked line stating a stale version             -> REFUSE, and never "edit the number"
#   3. a historical line is ignored BECAUSE of its entry -> break the anchor and it refuses
#   4. a HISTORICAL entry that matches nothing           -> REFUSE (a stale allowlist entry lies)
#   5. a HISTORICAL entry covering two lines             -> REFUSE (an over-broad anchor)
#   6. a marker on a line that states no claim           -> REFUSE (it verifies nothing)
#   7. an EXCLUDED path spelling the pin                 -> REFUSE (a copy nothing else looks at)
#   8. no occurrence and no marker anywhere              -> REFUSE rather than pass vacuously
#   9. a directory with no files at all                  -> exit 2, no verdict, never a pass
#  9b. the constant defined more than once               -> exit 2, no verdict, never a guess
#  10. the REAL repository                               -> accept
#  11. the check driven to red — three mutations, each of which must silence exactly one case above
#
# The refusal cases are the point. #69's `[7e]` sweep covered two files and said, in the issue it
# spawned, that the rest needed a policy rather than a wider regex — and the hazard in getting that
# policy wrong is not a missed copy but a WRONG EDIT: sweeping the deliberately-historical
# `xunit.v3.mtp-v2` enumerations into agreement destroys the distinction MTP_LINE encodes, and
# deriving the scratch .csproj fixture from the constant makes the transform test assert against
# its own output. So both directions are driven here, over fixtures.
#
# ⚠️ The fixtures pin a FAKE version (see $FAKE below), never the repo's real one. A suite that
# spelled the real pin would itself become an unmarked copy — and the check would be right to
# refuse it. It is also why scripts/pinned-literals-check.py excludes this directory, and why
# section 7 proves that exclusion cannot hide a real copy.
#
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/pinned-literals-check.py"
# Scratch dir and EXIT trap come from the shared preamble (#72). Sourced via $REPO, never $PWD:
# this suite does not cd, and an empty $WORK would resolve every fixture path against / .
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if [ ! -f "$CHECK" ]; then
  echo "FAIL: $CHECK does not exist — there is no guard to drive."
  exit 1
fi

# The fixtures' pin. Deliberately NOT the repo's real version: see the header.
FAKE=9.9.9

# Run a checker over a scratch repo; echo its output, return its status. The checker is a
# parameter so section 11 can drive a MUTATED copy through the very same cases.
run_with() { python3 "$1" --repo "$2" 2>&1; }
run_check() { run_with "$CHECK" "$1"; }

# Rewrite one line of a fixture file. `sed -i` is spelled differently on BSD and GNU, so this
# writes a sibling and moves it — the portable form, and the one that fails loudly on a bad path.
rewrite() {
  local file="$1" expr="$2"
  sed "$expr" "$file" > "$file.new" && mv "$file.new" "$file"
}

# --------------------------------------------------------------------------------- the baseline
#
# A miniature repo that is fully accounted for: the constant's own module, one marked line per
# scanned file, and a line for EVERY entry in the check's HISTORICAL table — because those entries
# name real paths and anchors, and an entry that matches nothing is itself a refusal. Building the
# baseline out of the real anchors is deliberate: it means these fixtures exercise the shipped
# table rather than a parallel one that could drift away from it.
scaffold() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/tests/xunit-v3" "$root/skills/legacy-upgrade/references"

  cat > "$root/tests/xunit-v3/apply-transform.py" <<PY
# The module that DEFINES the pin. Its own definition line is the source, not a copy.
#
#   xunit.v3        $FAKE -> xunit.v3.mtp-v1      -> Microsoft.Testing.Platform 1.9.1  # pinned:xunit-v3
#   xunit.v3.mtp-v2 $FAKE -> xunit.v3.core.mtp-v2 -> Microsoft.Testing.Platform 2.0.2
#
# Both are the same major, and \`xunit.v3.mtp-v2\` $FAKE are STABLE releases — so a map keyed on
# the major is inverted (measured from xunit.v3.core.mtp-v{1,2} $FAKE's nuspecs).
XUNIT_V3_PACKAGE = "xunit.v3"
XUNIT_V3_VERSION = "$FAKE"


def validate_pairing(xunit_package, version):
    # an older positional call would refuse a correct pair naming "$FAKE" as the serving package
    # — the slot is the point, not the number.
    return xunit_package, version
PY

  cat > "$root/tests/xunit-v3/test.sh" <<SH
#!/usr/bin/env bash
#     Measured (SDK 10.0.302, xunit.v3 $FAKE, CodeCoverage 17.14.2):  # pinned:xunit-v3
#
# Keyed on the package ID (measured: xunit.v3 $FAKE -> MTP 1.9.1,  # pinned:xunit-v3
# xunit.v3.mtp-v2 $FAKE -> MTP 2.0.2), so a version-keyed map would invert every pair below.
cat > "\$scratch/helper.csproj" <<XML
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="xunit.v3" Version="$FAKE" />
  </ItemGroup>
</Project>
XML
SH

  cat > "$root/skills/legacy-upgrade/references/xunit-v3-migration.md" <<MD
# Fixture reference

| xunit test package | resolves through | MTP | CodeCoverage |
|---|---|---|---|
| **\`xunit.v3\`** $FAKE | \`xunit.v3.mtp-v1\` | 1.9.1 | **17.x** <!-- pinned:xunit-v3 --> |
| **\`xunit.v3.mtp-v2\`** $FAKE | \`xunit.v3.core.mtp-v2\` | 2.0.2 | **18.x** |

Both are the same **major**, and \`xunit.v3.mtp-v2\` $FAKE are **stable**, not prerelease — so a
rule keyed on the major refuses the correct pair.
MD
}

# ----------------------------------------------- 0. the baseline is genuinely accounted for
# Every refusal below is a MUTATION of this baseline. If the baseline itself refused, each of them
# would "pass" for a reason that has nothing to do with the defect it names — the fixture-bug
# failure mode tests/ci-wiring/test.sh guards with assert_parsed.
BASE="$WORK/baseline"; scaffold "$BASE"
out=$(run_check "$BASE"); rc=$?
if [ $rc -eq 0 ]; then
  ok "the baseline fixture is fully accounted for (marked + historical)"
else
  bad "the baseline fixture must pass, but the check refused it (rc=$rc): $out"
fi

# ------------------------------------------------ 1. a new copy, neither marked nor recorded
# The case #90 exists for. A copy of the pin appears in a file nobody thought about; the check must
# REFUSE and name file:line, rather than sweep it into agreement (a wrong EDIT) or ignore it (what
# an exclusion list would have done).
R="$WORK/newcopy"; scaffold "$R"
mkdir -p "$R/docs"
printf 'Our CI pins xunit.v3 %s, measured last spring.\n' "$FAKE" > "$R/docs/notes.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && printf '%s' "$out" | grep -q 'docs/notes.md:1' \
   && printf '%s' "$out" | grep -q 'neither marked nor recorded'; then
  ok "an unmarked, unrecorded copy is refused, naming file:line"
else
  bad "expected a refusal naming docs/notes.md:1; got rc=$rc: $out"
fi

# ---------------------------------------------------- 2. a marked line that states a stale version
# The drift half, and the reason marking is not circular: this line is found BY ITS MARKER, so it
# is judged even though it no longer spells the current pin. The refusal must also say re-MEASURE
# — never "edit the number" — because these figures carry an MTP version and a CodeCoverage major
# that a real migration depends on ([7e]'s argument).
R="$WORK/stale"; scaffold "$R"
rewrite "$R/skills/legacy-upgrade/references/xunit-v3-migration.md" "s/\`xunit.v3\`\*\* $FAKE/\`xunit.v3\`** 1.2.3/"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && printf '%s' "$out" | grep -q 'xunit-v3-migration.md:5' \
   && printf '%s' "$out" | grep -q 'states xunit.v3 1.2.3' \
   && printf '%s' "$out" | grep -q 'Do NOT simply edit the number'; then
  ok "a marked line stating a stale version is refused, and told to re-measure"
else
  bad "expected a stale-marked refusal naming the row; got rc=$rc: $out"
fi

# ------------------------------------ 3. a historical line is ignored BECAUSE its entry matched it
# Section 0 shows the historical lines are accepted; on its own that proves nothing, since a line
# nothing looked at is accepted too. Break the ANCHOR only — the version stays — and the very same
# line must now be refused as a new copy. That is what makes the acceptance load-bearing.
R="$WORK/anchor"; scaffold "$R"
rewrite "$R/tests/xunit-v3/test.sh" 's/a version-keyed map would invert/a map keyed that way would flip/'
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && printf '%s' "$out" | grep -q 'tests/xunit-v3/test.sh:5' \
   && printf '%s' "$out" | grep -q 'neither marked nor recorded'; then
  ok "a historical line is accepted only because its entry matched it"
else
  bad "expected the un-anchored historical line to be refused; got rc=$rc: $out"
fi

# ------------------------------------------------- 4. a HISTORICAL entry that matches nothing
# A recorded occurrence that no longer exists is a claim about the repo that is no longer true, and
# an allowlist nobody prunes is how the next reader learns to distrust the whole table.
R="$WORK/stalentry"; scaffold "$R"
rewrite "$R/tests/xunit-v3/apply-transform.py" '/are STABLE releases/d'
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'matches nothing any more'; then
  ok "a HISTORICAL entry whose line is gone is refused, not silently carried"
else
  bad "expected a stale-entry refusal; got rc=$rc: $out"
fi

# ------------------------------------------------------- 5. a HISTORICAL entry covering two lines
# Each entry records ONE occurrence with ONE reason. An anchor broad enough to cover a second would
# swallow the next copy in silence — the exclusion-list failure this whole design rejects, rebuilt
# inside the allowlist.
R="$WORK/broad"; scaffold "$R"
# Read the line out FIRST, then append. `grep pattern f >> f` is a file that is its own output:
# BSD grep (macOS) does it, GNU grep (CI) refuses with "input file is also the output" and appends
# nothing — so the second occurrence never exists and this section passes vacuously on one platform
# while failing on the other. The suite's whole subject is copies of a literal; it must not create
# its own fixture in a way only one grep implementation performs.
dup_line=$(grep 'are STABLE releases' "$R/tests/xunit-v3/apply-transform.py")
[ -n "$dup_line" ] || bad "section 5 fixture: the line to duplicate was not found in the scaffold"
printf '%s\n' "$dup_line" >> "$R/tests/xunit-v3/apply-transform.py"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'covers 2 lines'; then
  ok "a HISTORICAL entry that covers two occurrences is refused as too broad"
else
  bad "expected an over-broad-anchor refusal; got rc=$rc: $out"
fi

# --------------------------------------------------- 6. a marker on a line that states no claim
# A marker that verifies nothing is worse than no marker: it reads, to the next author, as a line
# already under guard.
R="$WORK/noclaim"; scaffold "$R"
mkdir -p "$R/docs"
printf 'A note with no package id at all.  # pinned:xunit-v3\n' > "$R/docs/marked.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && printf '%s' "$out" | grep -q 'docs/marked.md:1' \
   && printf '%s' "$out" | grep -q 'states no `xunit.v3 <version>` claim'; then
  ok "a marker on a line carrying no claim is refused"
else
  bad "expected a no-claim refusal; got rc=$rc: $out"
fi

# ------------------------------------------------------- 7. an EXCLUDED path spelling the pin
# Two paths are excluded because they DEFINE and EXERCISE the marker convention. That exclusion is
# a hole of exactly the shape this check closes unless something proves nothing hides in it — so
# an excluded file may name the marker, but never the version.
R="$WORK/excluded"; scaffold "$R"
mkdir -p "$R/tests/pinned-literals"
printf 'A fixture note that leaks the real pin %s.\n' "$FAKE" > "$R/tests/pinned-literals/notes.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && printf '%s' "$out" | grep -q 'tests/pinned-literals/notes.md:1' \
   && printf '%s' "$out" | grep -q 'EXCLUDED from the scan'; then
  ok "an excluded path that spells the pin is refused, so the exclusion hides nothing"
else
  bad "expected an excluded-path refusal; got rc=$rc: $out"
fi

# ------------------------------------------------------ 8. no occurrence and no marker anywhere
# The vacuity guard. A repo where the scan finds nothing to judge must REFUSE: "all accounted for"
# over an empty set is the #45 failure — a check nobody notices has stopped looking.
R="$WORK/vacuous"; mkdir -p "$R/tests/xunit-v3"
{ printf 'XUNIT_V3_PACKAGE = "xunit.v3"\n'; printf 'XUNIT_V3_VERSION = "%s"\n' "$FAKE"; } \
  > "$R/tests/xunit-v3/apply-transform.py"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'verified NOTHING'; then
  ok "a repo where nothing carries the marker refuses instead of passing vacuously"
else
  bad "expected a vacuity refusal; got rc=$rc: $out"
fi

# --------------------------------------------------------- 9. a directory with no files at all
# Distinct from section 8 and reported differently: there is no repo to read, so no VERDICT was
# reached. Exit 2 says that; exit 0 would claim a pass, and exit 1 would blame the repo.
R="$WORK/empty"; rm -rf "$R"; mkdir -p "$R"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q 'refusing to report'; then
  ok "an empty directory yields no verdict (exit 2), never a pass"
else
  bad "expected exit 2 on an empty directory; got rc=$rc: $out"
fi

# ------------------------------------------------------- 9b. the constant defined more than once
# The check compares the WHOLE repo against one value, so which definition it read is not a detail.
# Taking the first would make the verdict depend on file order — a wrong answer that looks like a
# right one — so two definitions are a plumbing error rather than something to resolve.
R="$WORK/twopins"; scaffold "$R"
printf 'XUNIT_V3_VERSION = "1.2.3"\n' >> "$R/tests/xunit-v3/apply-transform.py"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q 'defined more than once'; then
  ok "two definitions of the constant yield no verdict (exit 2), never a guess"
else
  bad "expected exit 2 on a doubly-defined constant; got rc=$rc: $out"
fi

# ------------------------------------------------------------------- 10. the REAL repository
# The acceptance case. Without it the suite would prove the refusals work and say nothing about
# whether the repository it ships in is actually accounted for.
out=$(run_check "$REPO"); rc=$?
if [ $rc -eq 0 ]; then
  ok "the real repository is fully accounted for: $out"
else
  bad "the real repository must pass the check (rc=$rc): $out"
fi

# -------------------------------------------------------------- 11. the check, driven to red
# Each mutation neuters exactly one branch of the guard, and the case that branch serves must lose
# its evidence. Without this the sections above prove the check refuses SOMETHING — not that any
# particular assertion is load-bearing. The mutants are copies; the shipped script is never edited.
MUT="$WORK/mutants"; mkdir -p "$MUT"

# The mutant path comes back in a GLOBAL, never through `m=$(mutate …)`. Command substitution runs
# the function in a SUBSHELL: a `bad` call inside it would increment $fails in a copy that dies
# with the subshell, AND its FAIL line would be captured into $m instead of printed. A mutation
# whose sed stopped matching would then print nothing and exit 0 — a suite reporting green over an
# assertion it never made, which is the one outcome this repo treats as worse than a red run.
MUTANT=""
mutate() {  # <name> <sed-expr>; sets $MUTANT, returns non-zero if the mutation did not take
  local name="$1" expr="$2"
  MUTANT="$MUT/$name.py"
  cp "$CHECK" "$MUTANT" && rewrite "$MUTANT" "$expr" || {
    bad "mutation '$name' could not be built"; MUTANT=""; return 1; }
  if cmp -s "$CHECK" "$MUTANT"; then
    bad "mutation '$name' changed nothing — its sed no longer matches the check"
    MUTANT=""
    return 1
  fi
  return 0
}

# M1 — stop classifying unmarked lines at all. Section 1's copy must go unnamed.
if mutate blind-to-copies 's/^            if version not in line:$/            if True:/'; then
  out=$(run_with "$MUTANT" "$WORK/newcopy")
  if printf '%s' "$out" | grep -q 'docs/notes.md:1'; then
    bad "section 1 is not load-bearing: the blinded check still named docs/notes.md:1"
  else
    ok "mutation 'blind-to-copies' silences section 1 — that assertion is load-bearing"
  fi
fi

# M2 — stop comparing a marked line's claim to the constant. Section 2 must lose its refusal.
if mutate accept-stale-marks 's/^                stale = sorted(.*)$/                stale = []/'; then
  out=$(run_with "$MUTANT" "$WORK/stale")
  if printf '%s' "$out" | grep -q 'states xunit.v3 1.2.3'; then
    bad "section 2 is not load-bearing: the blinded check still refused the stale mark"
  else
    ok "mutation 'accept-stale-marks' silences section 2 — that assertion is load-bearing"
  fi
fi

# M3 — drop the vacuity guard. Section 8's repo must lose its "verified NOTHING" verdict.
#
# Asserted on the MESSAGE rather than on the exit status, deliberately: that fixture is a bare
# two-line module, so every HISTORICAL entry is stale there too and the mutant still exits 1 for
# that unrelated reason. Reading the exit status would let the vacuity guard rot behind a refusal
# it never issued — the same "green for the wrong reason" the parse sweep's CI step warns about.
if mutate no-vacuity-guard 's/^    if marked == 0:$/    if False:/'; then
  out=$(run_with "$MUTANT" "$WORK/vacuous")
  if printf '%s' "$out" | grep -q 'verified NOTHING'; then
    bad "section 8 is not load-bearing: the blinded check still reported the vacuity refusal"
  else
    ok "mutation 'no-vacuity-guard' silences section 8 — that assertion is load-bearing"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "pinned-literals golden test: all sections passed."
else
  echo "pinned-literals golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
