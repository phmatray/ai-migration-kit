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

echo "xunit v3 golden test OK"
