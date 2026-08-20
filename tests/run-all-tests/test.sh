#!/usr/bin/env bash
# Golden test for scripts/run-all-tests.sh (#170): the three exits, plus the guard that keeps its
# hand-written plan from drifting out of step with .github/workflows/ci.yml as CI grows.
set -euo pipefail
cd "$(dirname "$0")/../.."

RUNNER="./scripts/run-all-tests.sh"
[ -x "$RUNNER" ] || { echo "FAIL: $RUNNER missing or not executable"; exit 1; }
KIT="$PWD"

# Scratch dirs and EXIT trap come from the shared preamble (#72).
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

# ---------------------------------------------------------------- 1. exit 2: missing prerequisite
#
# run-all-tests.sh builds its whole plan as bash arrays of string literals before it ever touches
# the filesystem, and the preflight guard runs before any of them execute — so a stub tree only
# needs the runner itself plus a preflight.sh that refuses. Nothing else in the kit has to exist.
stub=$(kit_scratch)
mkdir -p "$stub/scripts"
cp "$KIT/scripts/run-all-tests.sh" "$stub/scripts/run-all-tests.sh"
cat > "$stub/scripts/preflight.sh" <<'EOF'
#!/usr/bin/env bash
echo "MISSING X  stub prerequisite — always refuses, for the exit-2 golden test" >&2
exit 1
EOF
chmod +x "$stub/scripts/run-all-tests.sh" "$stub/scripts/preflight.sh"

rc=0
stub_out=$(bash "$stub/scripts/run-all-tests.sh" 2>"$stub/stderr.log") || rc=$?
stub_err=$(cat "$stub/stderr.log")
[ "$rc" -eq 2 ] || {
  echo "FAIL [exit-2]: expected exit 2, got $rc"; echo "$stub_out"; echo "$stub_err"; exit 1; }
printf '%s' "$stub_err" | grep -qF 'PREREQUISITE' || {
  echo "FAIL [exit-2]: stderr did not mention PREREQUISITE:"; echo "$stub_err"; exit 1; }
if printf '%s' "$stub_out" | grep -q '^suite '; then
  echo "FAIL [exit-2]: suite output was printed despite the missing prerequisite:"; echo "$stub_out"
  exit 1
fi
echo "  ok: exit-2 — a missing prerequisite refuses before any suite runs, and says so on stderr"

# ---------------------------------------------------------------- 2. exit 1: a failing suite is named
#
# The real plan is hand-written and has no override hook (by design — it must run with no
# dependencies), so proving "a failing suite stops the run and is named" needs a real copy of the
# tree with one suite broken. The worktree this runs from is a LINKED worktree, so .git here is a
# small file rather than the object store — a full copy is a few megabytes, not the whole repo's
# history.
fixture="$(kit_scratch)/kit"
mkdir -p "$fixture"
rsync -a --exclude='.git' --exclude='.claude/worktrees' --exclude='.worktrees' "$KIT/" "$fixture/"
# Not a clone of KIT's history — a fresh, empty repository, committed once so every file is
# tracked. worktrees-ignored.sh (gate 1) needs to BE a git repo; ci-wiring-check.py (gate 2) needs
# every tests/*/test.sh to be staged, the same signal a real clone gives it.
git -C "$fixture" init -q -b main
cat > "$fixture/tests/lib/test.sh" <<'EOF'
#!/usr/bin/env bash
echo "deliberately broken for the run-all-tests golden test" >&2
exit 1
EOF
chmod +x "$fixture/tests/lib/test.sh"
git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@example.com -c user.name="Golden Test" commit -q -m fixture

rc=0
fixture_out=$(cd "$fixture" && ./scripts/run-all-tests.sh --quick 2>&1) || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [exit-1]: expected exit 1, got $rc"; echo "$fixture_out"; exit 1; }
printf '%s' "$fixture_out" | grep -qF 'FAIL tests/lib/test.sh' || {
  echo "FAIL [exit-1]: the failing suite was not named:"; echo "$fixture_out"; exit 1; }
echo "  ok: exit-1 — a failing suite stops the run (fail-fast) and is named"

# ---------------------------------------------------------------- 3. no drift from ci.yml
#
# Every `run:` command in ci.yml's `kit` job must appear in --list's output, except the documented
# skips: `uses:` steps (no `run:` at all), the PyYAML install (a CI setup step, not a check to
# reproduce — preflight.sh is what enforces PyYAML locally), and the network-only renovate
# acceptance gate (only added by --with-network). This is the guard from the issue's rejected
# Approach C, folded in as a TEST rather than as the generation mechanism: the plan stays
# hand-written, but it cannot silently fall behind what CI actually runs.
python3 - "$KIT" <<'PY'
import subprocess, sys, yaml

kit = sys.argv[1]
with open(f"{kit}/.github/workflows/ci.yml") as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["kit"]["steps"]

listing = subprocess.run(
    [f"{kit}/scripts/run-all-tests.sh", "--list"],
    cwd=kit, capture_output=True, text=True, check=True,
).stdout

DOCUMENTED_SKIPS = {
    "Install Python test dependencies",
    "renovate.json is a config Renovate actually accepts",
}

reproducible = [s for s in steps if "run" in s and s.get("name") not in DOCUMENTED_SKIPS]

missing = []
for step in reproducible:
    first_line = step["run"].strip().splitlines()[0]
    # A suite's ci.yml command is spelled "./tests/x/test.sh"; --list's suite lines drop the
    # leading "./" (they print the bare tests/x/test.sh path). Strip it before searching so the
    # comparison does not fail on that prefix for every suite in the job.
    needle = first_line[2:] if first_line.startswith("./") else first_line
    if needle not in listing:
        missing.append((step.get("name", "(unnamed)"), first_line))

if missing:
    print("FAIL [drift]: run-all-tests.sh --list is missing these ci.yml steps:")
    for name, line in missing:
        print(f"  - {name!r}: {line!r}")
    sys.exit(1)
print(f"  ok: drift — all {len(reproducible)} reproducible ci.yml steps appear in --list")
PY

echo "run-all-tests golden test OK"
