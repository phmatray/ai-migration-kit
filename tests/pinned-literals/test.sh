#!/usr/bin/env bash
# Golden test for scripts/pinned-literals-check.py — the guard that every spelling of the pinned
# xunit.v3 version is either MARKED as derived from the constant, or RECORDED as historical (#90).
#
# What this suite guards:
#   1. a new copy, neither marked nor recorded          -> REFUSE, naming file:line
#
# The refusal cases are the point. #69's `[7e]` sweep covered two files and said, in the issue it
# spawned, that the rest needed a policy rather than a wider regex — and the hazard in getting that
# policy wrong is not a missed copy but a WRONG EDIT: sweeping the deliberately-historical
# `xunit.v3.mtp-v2` enumerations into agreement destroys the distinction MTP_LINE encodes, and
# deriving the scratch .csproj fixture from the constant makes the transform test assert against
# its own output. So every refusal path is driven here, over fixtures.
#
# ⚠️ The fixtures pin a FAKE version (see $FAKE below), never the repo's real one. A suite that
# spelled the real pin would itself become an unmarked copy — and the check would be right to
# refuse it. It is also why scripts/pinned-literals-check.py excludes this directory, and why it
# refuses if an excluded path spells the pin after all.
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

# Run the checker over a scratch repo; echo its output, return its status.
run_check() { python3 "$CHECK" --repo "$1" 2>&1; }

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

# ------------------------------------------------------- 0. the baseline is genuinely accounted for
# Every refusal below is a MUTATION of this baseline. If the baseline itself refused, each of them
# would "pass" for a reason that has nothing to do with the defect it names — the fixture-bug
# failure mode tests/ci-wiring/test.sh guards with assert_parsed.
R="$WORK/baseline"; scaffold "$R"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "the baseline fixture is fully accounted for (marked + historical)"
else
  bad "the baseline fixture must pass, but the check refused it (rc=$rc): $out"
fi

# ---------------------------------------------------- 1. a new copy, neither marked nor recorded
# The case #90 exists for. A copy of the pin appears in a file nobody thought about; the check must
# REFUSE and name file:line, rather than sweep it into agreement (which would be a wrong EDIT) or
# ignore it (which is what an exclusion list would have done).
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

echo
if [ "$fails" -eq 0 ]; then
  echo "pinned-literals golden test: all sections passed."
else
  echo "pinned-literals golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
