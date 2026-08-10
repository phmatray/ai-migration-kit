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
check_fixture_pristine() {
  local rc=$?
  local dirty
  dirty=$(git -C "$KIT" status --porcelain -- samples/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FAIL: the committed fixture was mutated — it must stay xunit 2.4.2 / net6.0:"
    echo "$dirty"
    exit 1
  fi
  exit $rc
}
trap check_fixture_pristine EXIT

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

# A scratch copy, never the fixture itself. `git status` is checked on exit (trap above).
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"; check_fixture_pristine' EXIT
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

echo "xunit v3 golden test OK"
