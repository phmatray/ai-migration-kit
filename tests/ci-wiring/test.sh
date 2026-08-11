#!/usr/bin/env bash
# Golden test for scripts/ci-wiring-check.py — the guard that every tests/<name>/test.sh is run
# by a CI step that can actually fail the build (#45).
#
# What this suite guards:
#   1. the happy path on THIS repo — the real tests/ and the real .github/workflows/
#   2. a suite nothing invokes                        -> REFUSE, naming it
#   3. a step that is commented out                   -> REFUSE (the path survives as comment text)
#   4. a step marked continue-on-error: true          -> REFUSE (runs, fails, build stays green)
#   5. a step marked if: false                        -> REFUSE (never runs)
#   6. `run: ./tests/x/test.sh || true`               -> REFUSE (exit status discarded)
#   7. a workflow with no automatic trigger           -> REFUSE (workflow_dispatch is not CI)
#   8. an empty tests/ directory                      -> REFUSE, never a vacuous "all wired"
#   9. every tests/<name>/ named in README.md exists  -> the prose cannot outlive the directory
#
# The refusal cases are the point. A gate is worth exactly what its refusal path is worth, and an
# inline `run:` block cannot have one — which is why scripts/release-title-gate.sh was extracted
# from yaml after its inline version failed open, and why this one starts out extracted.
#
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/ci-wiring-check.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# Every refusal fixture is built with sed, and a fixture that did not come out as intended would
# ALSO be refused — by accident, for the wrong reason, reading as a pass. So each one is asserted
# against the parsed yaml before its verdict is trusted. (`\n` in a sed replacement is a GNU
# extension; this is what catches it if the suite is ever run where sed behaves differently.)
assert_parsed() {
  local file="$1" expr="$2" label="$3"
  python3 -c "
import sys, yaml
d = yaml.safe_load(open('$file'))
sys.exit(0 if ($expr) else 1)
" 2>/dev/null || { bad "fixture bug — $label did not come out as intended"; return 1; }
  return 0
}

# Run the checker over a scratch repo; echo its output, return its status.
run_check() { python3 "$CHECK" --repo "$1" 2>&1; }

# Build a scratch repo with the named suites and one workflow that wires all of them.
scaffold() {
  local root="$1"; shift
  mkdir -p "$root/.github/workflows"
  {
    echo 'name: ci'
    echo 'on:'
    echo '  pull_request:'
    echo 'jobs:'
    echo '  kit:'
    echo '    runs-on: ubuntu-latest'
    echo '    steps:'
    for s in "$@"; do
      mkdir -p "$root/tests/$s"
      touch "$root/tests/$s/test.sh"
      echo "      - name: $s golden test"
      echo "        run: ./tests/$s/test.sh"
    done
  } > "$root/.github/workflows/ci.yml"
}

echo "== ci-wiring-check golden test =="

# --------------------------------------------------------------- 1. the real repo passes
out=$(run_check "$REPO"); rc=$?
if [ $rc -eq 0 ]; then ok "this repo: every suite is enforced by CI"
else bad "this repo should pass but did not:"; printf '%s\n' "$out" | sed 's/^/        /'; fi

# --------------------------------------------------------------- 2. an uninvoked suite
R="$WORK/uninvoked"; scaffold "$R" alpha beta
mkdir -p "$R/tests/orphan"; touch "$R/tests/orphan/test.sh"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'tests/orphan/test.sh'; then
  ok "a suite nothing invokes is refused, and named"
else bad "expected refusal naming tests/orphan/test.sh; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 3. commented-out step
# The regression that made this a script: `grep` on the raw file accepts the leftover comment
# text, so the disabled suite reads as wired. Parsing the yaml removes the step entirely.
R="$WORK/commented"; scaffold "$R" alpha beta
sed -i.bak 's|^      - name: beta golden test|#      - name: beta golden test|; s|^        run: ./tests/beta/test.sh|#        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
grep -q '^#        run: ./tests/beta/test.sh' "$R/.github/workflows/ci.yml" \
  || bad "fixture bug: the beta step was not commented out"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'tests/beta/test.sh'; then
  ok "a commented-out step does not count as wired"
else bad "expected refusal for the commented-out beta step; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 4. continue-on-error
R="$WORK/soft"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        continue-on-error: true\n        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1].get('continue-on-error') is True" "continue-on-error"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'cannot fail the build'; then
  ok "continue-on-error: true does not count as wired"
else bad "expected refusal for continue-on-error; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 5. if: false
R="$WORK/iffalse"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        if: false\n        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1].get('if') is False" "if: false"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'cannot fail the build'; then
  ok "if: false does not count as wired"
else bad "expected refusal for if: false; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 6. `|| true`
R="$WORK/ortrue"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        run: ./tests/beta/test.sh \|\| true|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1]['run'].strip().endswith('|| true')" "|| true"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'tests/beta/test.sh'; then
  ok "a discarded exit status (|| true) does not count as wired"
else bad "expected refusal for '|| true'; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 7. no automatic trigger
R="$WORK/manual"; scaffold "$R" alpha
sed -i.bak 's|^on:|on:\n  workflow_dispatch:|; s|^  pull_request:||' "$R/.github/workflows/ci.yml"
# PyYAML reads YAML 1.1, so the bare key `on:` is the boolean True, not the string "on".
assert_parsed "$R/.github/workflows/ci.yml" \
  "list(d.get('on', d.get(True))) == ['workflow_dispatch']" "workflow_dispatch-only trigger"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'no automatic trigger'; then
  ok "a workflow_dispatch-only workflow is not CI"
else bad "expected refusal for a manual-only workflow; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 8. empty tests/
# Without this the glob matches nothing, the loop body never runs, and the checker would report
# "0 suites, all wired" — a pass that means the opposite of what it says.
R="$WORK/empty"; scaffold "$R" alpha
rm -rf "$R/tests"; mkdir -p "$R/tests"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'refusing to report'; then
  ok "an empty tests/ refuses instead of passing vacuously"
else bad "expected refusal on an empty tests/; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 9. README names real directories
# The README paragraph on hardening a destructive operation cites suites by name. That is a small
# enumeration of exactly the kind this issue removed, so it is pinned rather than trusted.
missing=
while read -r d; do
  [ -z "$d" ] && continue
  [ -d "$REPO/$d" ] || missing="$missing $d"
done < <(grep -oE 'tests/[a-z0-9][a-z0-9-]*/' "$REPO/README.md" | sort -u)
if [ -z "$missing" ]; then
  ok "every tests/<name>/ named in README.md exists"
else
  bad "README.md names directories that do not exist:$missing"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ci-wiring golden test: all sections passed."
else
  echo "ci-wiring golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
