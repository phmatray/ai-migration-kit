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

# Section 7 injects a bad coverage version through this variable. Inherited from the caller's
# environment it would instead redirect EVERY transform below onto a version nobody chose — the
# suite would still be green, having tested something other than the pin it claims to test. The
# only place it may be set is the one invocation that means to set it.
unset XUNIT_V3_COVERAGE_VERSION

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
#
#     The run must SUCCEED and report its tests first. Swallowing the exit code and only asking
#     "is there a cobertura file?" would let a restore failure or a build break satisfy the pin
#     without the collector ever having run — a green assertion proving nothing.
rm -rf coverage
if ! dotnet test --nologo --collect:"XPlat Code Coverage" --results-directory coverage \
     > "$scratch/vstest-cov.log" 2>&1; then
  echo "FAIL: the VSTest-collector run failed outright, so 4a would pass for the wrong reason:"
  tail -20 "$scratch/vstest-cov.log"; exit 1
fi
vcount=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$scratch/vstest-cov.log" | head -1)
if [ "${vcount:-0}" -lt "$BASELINE_TESTS" ]; then
  echo "FAIL: 4a ran ${vcount:-0} tests (baseline $BASELINE_TESTS) — the tests must actually run"
  echo "      for 'no coverage file' to mean the collector was ignored."
  tail -20 "$scratch/vstest-cov.log"; exit 1
fi
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

# ---------------------------------------------------------------------------
# 6. Project shapes the fixture does not have.
#
#    The fixture is one tidy SDK-style csproj with self-closing PackageReferences and two-space
#    indentation. Every assertion above would still pass if the tools only worked on THAT shape.
#    These cases came out of code review, each having silently produced a wrong result:
#    a surviving VSTest adapter, a transform that did nothing, a dropped target framework, an
#    invisible legacy test project, and a null major line under central package management.
# ---------------------------------------------------------------------------
shapes="$scratch/shapes"
mkdir -p "$shapes"

# 6a. `dotnet new xunit` writes the adapter in ELEMENT form with <PrivateAssets> children.
mkdir -p "$shapes/element/p"
cat > "$shapes/element/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.1">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
    </PackageReference>
    <PackageReference Include="coverlet.collector" Version="6.0.2">
      <PrivateAssets>all</PrivateAssets>
    </PackageReference>
  </ItemGroup>
</Project>
XML
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/element" > /dev/null
if grep -q 'xunit.runner.visualstudio\|coverlet.collector' "$shapes/element/p/p.csproj"; then
  echo "FAIL: element-form VSTest packages survived — half-swapped test host:"
  cat "$shapes/element/p/p.csproj"; exit 1
fi
grep -q '<OutputType>Exe</OutputType>' "$shapes/element/p/p.csproj" || {
  echo "FAIL: element-form project got no OutputType"; exit 1; }

# 6b. A csproj that is not indented two spaces must not silently skip the properties.
mkdir -p "$shapes/flat/p"
cat > "$shapes/flat/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup>
<TargetFramework>net8.0</TargetFramework>
</PropertyGroup>
<ItemGroup>
<PackageReference Include="xunit" Version="2.9.3" />
</ItemGroup>
</Project>
XML
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/flat" > /dev/null
for needle in '<OutputType>Exe</OutputType>' 'TestingPlatformDotnetTestSupport' 'xunit.v3'; do
  grep -q "$needle" "$shapes/flat/p/p.csproj" || {
    echo "FAIL: unindented csproj lost '$needle' — the transform no-opped and claimed success:"
    cat "$shapes/flat/p/p.csproj"; exit 1; }
done

# 6c. Multi-targeting must survive: only the legs below the v3 floor move.
mkdir -p "$shapes/multi/p"
cat > "$shapes/multi/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>net6.0;net8.0</TargetFrameworks>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.9.3" />
  </ItemGroup>
</Project>
XML
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/multi" > /dev/null
grep -q '<TargetFrameworks>net10.0;net8.0</TargetFrameworks>' "$shapes/multi/p/p.csproj" || {
  echo "FAIL: multi-targeting was collapsed — a published library would lose a target:"
  grep TargetFramework "$shapes/multi/p/p.csproj"; exit 1; }

# 6d. A packages.config test project (legacy .NET Framework — the kit's core audience) must
#     appear in testStack, not vanish behind an empty PackageReference list.
mkdir -p "$shapes/legacy/tests"
cat > "$shapes/legacy/tests/Legacy.Tests.csproj" <<'XML'
<Project ToolsVersion="12.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
XML
cat > "$shapes/legacy/tests/packages.config" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="xunit" version="2.4.1" targetFramework="net472" />
  <package id="xunit.runner.visualstudio" version="2.4.3" targetFramework="net472" />
</packages>
XML
legacy_inv=$("$KIT/scripts/audit-inventory.sh" "$shapes/legacy")
python3 - "$legacy_inv" <<'PY'
import json, sys
stack = json.loads(sys.argv[1]).get("testStack", [])
assert len(stack) == 1, f"packages.config test project invisible in testStack: {stack}"
assert stack[0]["xunitMajor"] == 2, stack[0]
assert stack[0]["packageSource"] == "packages.config", stack[0]
PY

# 6e. Central package management: the version lives in Directory.Packages.props, so a
#     Version-less PackageReference must still yield a major line.
mkdir -p "$shapes/cpm/tests"
cat > "$shapes/cpm/Directory.Packages.props" <<'XML'
<Project>
  <ItemGroup>
    <PackageVersion Include="xunit" Version="2.9.3" />
  </ItemGroup>
</Project>
XML
cat > "$shapes/cpm/tests/Cpm.Tests.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" />
  </ItemGroup>
</Project>
XML
cpm_inv=$("$KIT/scripts/audit-inventory.sh" "$shapes/cpm")
python3 - "$cpm_inv" <<'PY'
import json, sys
stack = json.loads(sys.argv[1]).get("testStack", [])
assert len(stack) == 1, stack
assert stack[0]["xunitMajor"] == 2, \
    f"CPM version unresolved -> xunitMajor {stack[0]['xunitMajor']}; phase 5 would read 'not applicable'"
PY
echo "  [6/6] element-form refs, flat indent, multi-TFM, packages.config and CPM all handled"

# 6f. The template refuses a half-migrated repo instead of silently losing half its coverage.
grep -q 'Dépôt MIXTE' templates/ci-dotnet.yml \
  || { echo "FAIL: templates/ci-dotnet.yml does not detect a mixed MTP/VSTest repo"; exit 1; }
echo "  [6/6] templates/ci-dotnet.yml refuses a mixed MTP/VSTest repo"

# ---------------------------------------------------------------------------
# 7. The xunit.v3 / CodeCoverage pairing is machine-checked, not remembered.
#
#    The two pinned versions must sit on the same Microsoft.Testing.Platform line, and a mismatch
#    is invisible to every static check: it restores, it compiles, and it dies at RUN time with
#    `TypeLoadException: Could not load type '…IDataConsumer'`. Section 2 would catch it — it
#    executes the tests — but only as a stack trace, which is an expensive way to rediscover a
#    known rule. So the transform states the rule and refuses up front, naming both versions.
# ---------------------------------------------------------------------------
read_const() {  # import the transform and print one of its constants (no .pyc next to the kit)
  PYTHONDONTWRITEBYTECODE=1 python3 - "$KIT/tests/xunit-v3/apply-transform.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("apply_transform", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(getattr(mod, sys.argv[2]))
PY
}
xunit_version=$(read_const XUNIT_V3_VERSION)

# The bad version is DERIVED, never hardcoded: one major above whatever the kit currently pins is
# a mismatch by construction, on today's 3.x/17.x pairing and on every future one. A literal
# "18.0.0" here would quietly become the *correct* partner the day xunit.v3 moves to 4.x, and this
# assertion would then fail for a reason that has nothing to do with what it is testing.
bad_coverage="$(( $(read_const COVERAGE_EXT_VERSION | cut -d. -f1) + 1 )).0.0"

mkdir -p "$shapes/pairing/p"
cat > "$shapes/pairing/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.9.3" />
  </ItemGroup>
</Project>
XML
cp "$shapes/pairing/p/p.csproj" "$scratch/pairing-before.csproj"

# 7a. A deliberately mismatched pair must be refused, non-zero, before anything is written.
pair_log="$scratch/pairing.log"
if XUNIT_V3_COVERAGE_VERSION="$bad_coverage" \
   python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/pairing" > "$pair_log" 2>&1; then
  echo "FAIL: the transform accepted CodeCoverage $bad_coverage alongside xunit.v3 $xunit_version."
  echo "      That pair builds clean and dies at run time — the mismatch must be refused here."
  exit 1
fi
# Establish WHICH refusal fired before asserting what it says: an unknown-package-id refusal names
# only the id, so without this the next reader is sent after a message-formatting bug when the real
# defect is a missing MTP_COMPAT entry.
grep -qF 'incompatible test platform pair' "$pair_log" || {
  echo "FAIL: the transform refused, but not for the pairing reason — the mismatch branch never"
  echo "      ran, so nothing here proves the pairing is checked:"; cat "$pair_log"; exit 1; }
for needle in "$xunit_version" "$bad_coverage"; do
  grep -qF "$needle" "$pair_log" || {
    echo "FAIL: the refusal does not name '$needle' — it must state BOTH versions, or the next"
    echo "      reader is back to diagnosing a TypeLoadException:"; cat "$pair_log"; exit 1; }
done
cmp -s "$shapes/pairing/p/p.csproj" "$scratch/pairing-before.csproj" || {
  echo "FAIL: the bad pair was refused, but only after rewriting the csproj — the check must"
  echo "      run before the transform touches anything."; exit 1; }

# 7b. The map is the contract: the pinned pair satisfies it, and an unmapped major says so
#     instead of guessing a compatible extension.
PYTHONDONTWRITEBYTECODE=1 python3 - "$KIT/tests/xunit-v3/apply-transform.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("apply_transform", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# The package/version this kit actually pins agree with the map.
mod.validate_pairing(mod.XUNIT_V3_PACKAGE, mod.COVERAGE_EXT_VERSION)

# The rule is keyed on the PACKAGE ID, not the major. `xunit.v3` and `xunit.v3.mtp-v2` are both on
# major 3 today and sit on opposite MTP lines (measured: xunit.v3 3.2.2 -> MTP 1.9.1,
# xunit.v3.mtp-v2 3.2.2 -> MTP 2.0.2), so a version-keyed map would invert this pair. Pin both
# directions: each id accepts its own partner and refuses the other's.
for pkg, good, bad in (("xunit.v3", "17.14.2", "18.9.0"),
                       ("xunit.v3.mtp-v2", "18.9.0", "17.14.2")):
    mod.validate_pairing(pkg, good)
    try:
        mod.validate_pairing(pkg, bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"{pkg} accepted CodeCoverage {bad} — the guard is inverted")

# A package id nobody has mapped must be named as such, not silently assumed compatible. Assert on
# a substring unique to THAT branch: both refusals mention MTP_COMPAT, so matching on the map name
# alone would keep passing if this case started taking the mismatch branch instead.
try:
    mod.validate_pairing("xunit.v3.mtp-v99", mod.COVERAGE_EXT_VERSION)
except ValueError as exc:
    assert "unknown xunit.v3 package id" in str(exc), f"wrong refusal branch: {exc}"
else:
    raise AssertionError("an unmapped xunit.v3 package id was accepted — the map would be bypassed")
PY
echo "  [7/7] the MTP/coverage pairing is enforced by the transform, not by memory"

echo "xunit v3 golden test OK"
