#!/usr/bin/env bash
# xunit v2 -> v3 golden test.
#
# Guards the phase-5 "test platform" item end to end:
#   1. the inventory reports the test stack precisely enough to decide the v2/v3 question;
#   2. the documented transform really produces a running v3 test project;
#   3. the OutputType trap — a v3 project left as a library — is pinned as 0 tests, not 6;
#   4. coverage still reaches the dashboard under the Microsoft Testing Platform;
#   5. the committed fixture is never mutated (CI asserts it stays "green AND legacy").
#
# Everything that builds runs on a COPY under $(mktemp -d). samples/LegacyShop is read-only here.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
FIXTURE="$KIT/samples/LegacyShop"

# The fixture is the "before" state and must survive this script untouched, on every exit path
# (including a failure mid-run) — otherwise a red test would also silently rewrite the fixture.
#
# `rc=$?` must be the FIRST thing this function does: anything before it (a cleanup `rm`, an
# `echo`) overwrites the exit status being reported, which would turn every failure below into
# a silent green — the exact class of bug this whole test exists to catch.
cleanup() {
  local rc=$?
  [ -n "${scratch:-}" ] && rm -rf "$scratch"
  local dirty
  dirty=$(git -C "$KIT" status --porcelain -- samples/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FAIL: the committed fixture was mutated — it must stay xunit 2.4.2 / net6.0:"
    echo "$dirty"
    exit 1
  fi
  # Nor may the run leave build droppings in the kit: a __pycache__ next to a kit script is how
  # a stray .pyc got committed once.
  if find "$KIT/scripts" "$KIT/tests" -name '__pycache__' -type d 2>/dev/null | grep -q .; then
    echo "FAIL: the test left a __pycache__ inside the kit — it must not modify the repo it tests."
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. The inventory reports the test stack (phase 1 needs it to decide v2 vs v3).
# ---------------------------------------------------------------------------
inv=$(./scripts/audit-inventory.sh "$FIXTURE")
python3 - "$inv" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
stack = inv.get("testStack")
assert stack is not None, "audit-inventory.sh emits no testStack key"
assert len(stack) == 1, f"expected 1 test project in the fixture, got {len(stack)}: {stack}"
entry = stack[0]
assert entry["project"].endswith("LegacyShop.Tests.csproj"), entry["project"]
assert entry["targetFrameworks"] == "net6.0", entry["targetFrameworks"]
want = {
    "xunit": "2.4.2",
    "xunit.runner.visualstudio": "2.4.5",
    "Microsoft.NET.Test.Sdk": "17.3.2",
}
for pkg, version in want.items():
    got = entry["packages"].get(pkg)
    assert got == version, f"{pkg}: expected {version}, got {got}"
# The whole point of the key: the major line must be readable without re-parsing versions.
assert entry["xunitMajor"] == 2, entry["xunitMajor"]
PY
echo "  [1/4] inventory reports the fixture's test stack (xunit 2.4.2, net6.0)"

# ---------------------------------------------------------------------------
# 2. The documented transform produces a test project that actually RUNS.
#
#    "It builds" is explicitly not the gate — the gate is the number of tests that execute,
#    compared to the phase-2 baseline. The fixture's baseline is 6.
# ---------------------------------------------------------------------------
BASELINE_TESTS=6

# A scratch copy, never the fixture itself. The EXIT trap removes it and checks `git status`.
scratch=$(mktemp -d)
cp -R "$FIXTURE" "$scratch/v3"

# The fixture has no ITestOutputHelper, so the namespace half of the transform would go
# unexercised. Inject the v2 idiom into the COPY so the rewrite is genuinely proven: under v3
# this file only compiles if `Xunit.Abstractions` became `Xunit`.
python3 - "$scratch/v3" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]) / "tests/LegacyShop.Tests/OrderServiceTests.cs"
t = p.read_text(encoding="utf-8")
t = t.replace("using Xunit;", "using Xunit;\nusing Xunit.Abstractions;")
t = t.replace(
    "        private readonly OrderService _service = new OrderService();",
    "        private readonly OrderService _service = new OrderService();\n"
    "        private readonly ITestOutputHelper _output;\n\n"
    "        public OrderServiceTests(ITestOutputHelper output)\n"
    "        {\n"
    "            _output = output;\n"
    "        }",
)
p.write_text(t, encoding="utf-8")
PY
grep -q 'using Xunit.Abstractions;' "$scratch/v3/tests/LegacyShop.Tests/OrderServiceTests.cs"

python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/v3" > /dev/null

# The namespace rewrite really happened (v3 has no Xunit.Abstractions to resolve).
if grep -q 'using Xunit.Abstractions;' "$scratch/v3/tests/LegacyShop.Tests/OrderServiceTests.cs"; then
  echo "FAIL: the transform left 'using Xunit.Abstractions;' in place"; exit 1
fi

v3_out="$scratch/v3-test.log"
if ! dotnet test "$scratch/v3/tests/LegacyShop.Tests/LegacyShop.Tests.csproj" \
     --nologo > "$v3_out" 2>&1; then
  echo "FAIL: the transformed v3 project did not run green:"; tail -25 "$v3_out"; exit 1
fi
count=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$v3_out" | head -1)
if [ "${count:-0}" -lt "$BASELINE_TESTS" ]; then
  echo "FAIL: v3 ran ${count:-0} tests, baseline is $BASELINE_TESTS — a build is not a test run:"
  tail -25 "$v3_out"; exit 1
fi
echo "  [2/4] transform -> xunit.v3 runs $count tests (baseline $BASELINE_TESTS), usings rewritten"

# ---------------------------------------------------------------------------
# 3. The OutputType trap is pinned.
#
#    A v3 test project left as a library must never yield a green 6-test run. On xunit.v3
#    3.2.2 the package guards this itself, failing the BUILD with an explicit message — so
#    what is asserted here is the guard, not a silent 0-test pass. If a future version drops
#    that guard, this assertion still holds: the run must not come back green with the full
#    test count. That is why the counted-tests gate, not this guard, is the contract.
# ---------------------------------------------------------------------------
cp -R "$FIXTURE" "$scratch/trap"
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/trap" --skip-output-type > /dev/null
grep -q '<OutputType>Exe</OutputType>' "$scratch/trap/tests/LegacyShop.Tests/LegacyShop.Tests.csproj" \
  && { echo "FAIL: --skip-output-type still emitted OutputType"; exit 1; }

trap_out="$scratch/trap-test.log"
if dotnet test "$scratch/trap/tests/LegacyShop.Tests/LegacyShop.Tests.csproj" \
   --nologo > "$trap_out" 2>&1; then
  trap_count=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$trap_out" | head -1)
  if [ "${trap_count:-0}" -ge "$BASELINE_TESTS" ]; then
    echo "FAIL: a v3 project without OutputType=Exe reported $trap_count tests green."
    echo "      That means the trap is live and undetectable — the counted-tests gate is the"
    echo "      only thing standing between a migration and a test suite that never runs."
    exit 1
  fi
  echo "  [3/4] no-Exe variant ran ${trap_count:-0} tests (< baseline) — not a green suite"
else
  grep -qi 'OutputType' "$trap_out" || {
    echo "FAIL: the no-Exe variant failed, but not for the OutputType reason:"; tail -20 "$trap_out"; exit 1
  }
  echo "  [3/4] no-Exe variant is refused at build time by xunit.v3 (OutputType guard)"
fi

# ---------------------------------------------------------------------------
# 4. Coverage still reaches the dashboard.
#
#    This is the half of the migration nothing else would catch. Under MTP the VSTest
#    collector is IGNORED — `dotnet test --collect:"XPlat Code Coverage"` exits 0, passes every
#    test, and writes no coverage file whatsoever (only a MTP0001 warning). The CI step would
#    then upload an empty artifact and report-dashboard.py would render "no coverage" for a
#    migration that is in fact tested. Both halves are pinned here: the hole, and the fix.
# ---------------------------------------------------------------------------
cd "$scratch/v3"

# 4a. The VSTest incantation produces nothing under MTP. If a future SDK makes it work again,
#     this assertion flips and the template's dual path can be simplified — deliberately loud.
rm -rf coverage
dotnet test --nologo --collect:"XPlat Code Coverage" --results-directory coverage \
  > "$scratch/vstest-cov.log" 2>&1 || true
if find coverage -name 'coverage.cobertura.xml' 2>/dev/null | grep -q .; then
  echo "NOTE: --collect:\"XPlat Code Coverage\" now yields cobertura under MTP."
  echo "      templates/ci-dotnet.yml can drop its MTP branch — re-check before simplifying."
  exit 1
fi
grep -q 'MTP0001' "$scratch/vstest-cov.log" \
  || echo "  (warning: MTP0001 no longer emitted — the ignore is now fully silent)"
echo "  [4/4a] VSTest collector yields no cobertura under MTP — the silent hole, pinned"

# 4b. The documented MTP path puts it back, in coverage/, where the artifact glob already looks.
rm -rf coverage && mkdir -p coverage
dotnet test --nologo -- --coverage --coverage-output-format cobertura \
  --coverage-output "$PWD/coverage/coverage.cobertura.xml" > "$scratch/mtp-cov.log" 2>&1
[ -f coverage/coverage.cobertura.xml ] || {
  echo "FAIL: the MTP coverage path produced no cobertura:"; tail -20 "$scratch/mtp-cov.log"; exit 1
}
PYTHONDONTWRITEBYTECODE=1 python3 - "$KIT" "$PWD/coverage/coverage.cobertura.xml" <<'PY'
# Loading report-dashboard.py as a module would drop a scripts/__pycache__ next to it and leave
# the kit's own tree dirty after every run — the test must not modify the repo it tests.
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rd", sys.argv[1] + "/scripts/report-dashboard.py")
rd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rd)
cov = rd.parse_cobertura(sys.argv[2], [])
covered = sum(c["covered"] for c in cov["classes"])
assert covered > 0, "parse_cobertura read zero covered lines — the dashboard would show nothing"
assert cov["line_pct"] > 0, f"line_pct is {cov['line_pct']}"
print(f"  [4/4b] MTP coverage -> cobertura -> parse_cobertura: "
      f"{covered} covered lines, {cov['line_pct']}% line rate")
PY
cd "$KIT"

# 4c. The template carries both paths and refuses to pass silently on an empty coverage dir.
grep -q 'coverage-output-format cobertura' templates/ci-dotnet.yml \
  || { echo "FAIL: templates/ci-dotnet.yml has no MTP coverage path"; exit 1; }
grep -q 'Aucun rapport de couverture' templates/ci-dotnet.yml \
  || { echo "FAIL: templates/ci-dotnet.yml has no guard against an empty coverage report"; exit 1; }
echo "  [4/4c] templates/ci-dotnet.yml carries the MTP path and the empty-coverage guard"

# ---------------------------------------------------------------------------
# 5. The decision is wired into the pipeline, not just documented in a side file.
#
#    A reference nobody is routed to is a reference nobody reads: phase 1 must surface the line,
#    phase 5 must own the gated item, and phase 6 must make the result land in the report.
# ---------------------------------------------------------------------------
grep -q 'xunitMajor' skills/legacy-upgrade/references/phase-1-assess.md \
  || { echo "FAIL: phase-1-assess.md does not record the xunit major line"; exit 1; }
grep -q 'xunit-v3-migration.md' skills/legacy-upgrade/references/phase-5-modernize.md \
  || { echo "FAIL: phase-5-modernize.md does not route to xunit-v3-migration.md"; exit 1; }
grep -qi 'baseline' skills/legacy-upgrade/references/phase-5-modernize.md \
  || { echo "FAIL: phase-5-modernize.md states no counted-tests gate"; exit 1; }
grep -qi 'test platform\|plateforme de test' skills/legacy-upgrade/references/phase-6-verify.md \
  || { echo "FAIL: phase-6-verify.md does not record the test platform"; exit 1; }
grep -qi 'plateforme de test' skills/legacy-upgrade/references/report-template.md \
  || { echo "FAIL: report-template.md has no slot for the test platform"; exit 1; }
echo "  [5/5] phases 1, 5 and 6 carry the decision, the route and the recorded outcome"

echo "xunit v3 golden test OK"
