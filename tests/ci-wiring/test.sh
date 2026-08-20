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
#   8. a pull_request-only workflow                   -> REFUSE (#133: never runs on a push to main)
#   9. push-to-main AND pull_request                  -> accept (the fix must not refuse ci.yml)
#  10. every other `push:` filter shape               -> the branch filter is actually read
#  11. an empty tests/ directory                      -> REFUSE, never a vacuous "all wired"
#  12. every tests/<name>/ named in README.md exists  -> the prose cannot outlive the directory
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
# Scratch dir and EXIT trap come from the shared preamble (#72).
#
# Sourced via $REPO, never $PWD: this suite deliberately does NOT cd — it is written to run from
# anywhere — and it sets `set -uo pipefail` without `-e`. With `$PWD` the source silently failed
# off-root, `kit_init`/`kit_scratch` were then "command not found", `WORK` stayed empty, and every
# fixture path resolved against the filesystem ROOT (`mkdir /uninvoked`, `rm -rf /empty/tests`).
# CI never saw it because CI invokes from the repo root.
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
WORK=$(kit_scratch)

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# Refusal fixtures are built by mutating a scaffolded workflow — with sed for the step-level cases,
# by overriding $TRIGGERS for the workflow-level ones — and a fixture that did not come out as
# intended would ALSO be refused: by accident, for the wrong reason, reading as a pass. So each one
# is asserted against the parsed yaml before its verdict is trusted. (`\n` in a sed replacement is a
# GNU extension; this is what catches it if the suite is ever run where sed behaves differently.)
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

# The `on:` block scaffold() writes. The default is the shape the real ci.yml carries — a push to
# `main` AND pull requests — because that is what every step-level fixture below means by "an
# otherwise normal CI workflow". It used to be `pull_request:` alone, which was harmless only while
# the guard treated the four automatic triggers as interchangeable; once a PR-only workflow is a
# refusal in its own right (#133), a PR-only scaffold would give sections 2-6 a SECOND, workflow-level
# reason to refuse, and each of those assertions would then pass without proving the step-level
# defect it names.
#
# A fixture that is about the trigger itself sets TRIGGERS before calling scaffold; scaffold resets
# it afterwards, so an override can never leak into the next fixture.
DEFAULT_TRIGGERS=$'on:\n  push:\n    branches: [main]\n  pull_request:'
TRIGGERS="$DEFAULT_TRIGGERS"

# Build a scratch repo with the named suites and one workflow that wires all of them. Each
# scratch root is a real git repository — the mode probe reads the INDEX, never the filesystem
# (that is the whole point: a Windows checkout's working-copy mode lies), so a fixture with no
# `.git` at all would make the probe refuse every section below for "not a repository" instead of
# whatever that section actually means to test. Every suite is staged at its real, correct 100755
# here; the sections that mean to test the mode probe itself override one path afterwards.
scaffold() {
  local root="$1"; shift
  mkdir -p "$root/.github/workflows"
  git -C "$root" init -q
  local s
  for s in "$@"; do
    mkdir -p "$root/tests/$s"
    touch "$root/tests/$s/test.sh"
    chmod +x "$root/tests/$s/test.sh"
    git -C "$root" add -- "tests/$s/test.sh"
  done
  {
    echo 'name: ci'
    printf '%s\n' "$TRIGGERS"
    echo 'jobs:'
    echo '  kit:'
    echo '    runs-on: ubuntu-latest'
    echo '    steps:'
    for s in "$@"; do
      echo "      - name: $s golden test"
      echo "        run: ./tests/$s/test.sh"
    done
  } > "$root/.github/workflows/ci.yml"
  TRIGGERS="$DEFAULT_TRIGGERS"
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
R="$WORK/manual"; TRIGGERS=$'on:\n  workflow_dispatch:'; scaffold "$R" alpha
# PyYAML reads YAML 1.1, so the bare key `on:` is the boolean True, not the string "on".
assert_parsed "$R/.github/workflows/ci.yml" \
  "list(d.get('on', d.get(True))) == ['workflow_dispatch']" "workflow_dispatch-only trigger"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'no automatic trigger'; then
  ok "a workflow_dispatch-only workflow is not CI"
else bad "expected refusal for a manual-only workflow; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 8. pull_request-only workflow
# #133. `push`, `pull_request`, `pull_request_target` and `schedule` used to be interchangeable
# evidence of "automatically triggered", and any one of them was enough. That was accidentally
# sufficient only because ci.yml was the sole run:-bearing workflow in the repo and it carries BOTH
# push-to-main and pull_request — so "automatically triggered" silently also meant "runs on main".
# #119 added .github/workflows/release-title.yml, triggered on pull_request alone, and removed the
# coincidence. A suite wired only there never runs on the push that lands on `main`, which is the
# last verdict before release-please cuts a tag: green guard, absent coverage, no diagnostic — the
# guard's own stated failure mode, reappearing through a case its model did not represent.
R="$WORK/pronly"; TRIGGERS=$'on:\n  pull_request:'; scaffold "$R" alpha
assert_parsed "$R/.github/workflows/ci.yml" \
  "list(d.get('on', d.get(True))) == ['pull_request']" "pull_request-only trigger"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'tests/alpha/test.sh' \
   && printf '%s' "$out" | grep -q 'never on a push to main'; then
  ok "a pull_request-only workflow does not count as enforcing a suite"
else bad "expected refusal naming tests/alpha/test.sh and the PR-only reason; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 9. both triggers still pass
# The other half of #133, and the one that costs something if it breaks: requiring a push-to-main
# trigger must NOT over-refuse the real ci.yml, which carries `push: branches: [main]` alongside
# `pull_request`. Section 1 already asserts that against the live repo, but section 1 fails for any
# reason at all; this pins the specific shape, so the guarantee survives an unrelated edit to this
# repo's own workflows.
R="$WORK/bothtriggers"; scaffold "$R" alpha beta
assert_parsed "$R/.github/workflows/ci.yml" \
  "sorted(d.get('on', d.get(True))) == ['pull_request', 'push']
   and d.get('on', d.get(True))['push']['branches'] == ['main']" \
  "push-to-main plus pull_request"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "a workflow on both push:main and pull_request still counts as enforcing"
else bad "expected acceptance for a push:main + pull_request workflow; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 10. the branch filter is read
# "Runs on a push to main" is not "has a push: key": the branch filter decides it, and most of the
# shapes below are a way for a push trigger to exist and still never fire on `main`. Table-driven,
# because the interesting part is the filter rather than the fixture — one section apiece would be a
# dozen near-identical copies of the block above.
#
# The `!` rows are the subtle ones. `!` is filter syntax, not part of a branch name, and GitHub lets
# the LAST matching pattern in the list decide — so `["**", "!main"]` does NOT run on main and
# `["!main", "**"]` does. Read as an unordered "does any pattern match", the first of those two
# reads as enforced: the same fail-open this whole issue is about, one level down inside the fix.
#
# Each case is asserted parsed before its verdict is read, for the reason at the top of this file:
# a mangled `on:` block would be refused too, by accident, and every want=1 row would then pass
# without exercising anything. The reason substring is the second half of that guard — it is what
# separates "refused because the branch filter misses main" from "refused for some other reason".
trigger_case() {
  local name="$1" on_block="$2" want="$3" label="$4" expect="${5:-}"
  local R="$WORK/trigger-$name" out rc
  TRIGGERS="$on_block"; scaffold "$R" alpha
  assert_parsed "$R/.github/workflows/ci.yml" \
    "bool(d.get('on', d.get(True)))
     and d['jobs']['kit']['steps'][0]['run'].strip() == './tests/alpha/test.sh'" \
    "$label" || return
  out=$(run_check "$R"); rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$label: expected exit $want, got $rc: $out"; return
  fi
  if [ -n "$expect" ] && ! printf '%s' "$out" | grep -q "$expect"; then
    bad "$label: exit $want as expected, but the reason never said '$expect': $out"; return
  fi
  ok "$label"
}

trigger_case nofilter $'on:\n  push:' 0 \
  "push: with no branches filter runs on every branch, main included"
trigger_case listwithmain $'on:\n  push:\n    branches: [main, release/*]' 0 \
  "a branches list that names main counts"
trigger_case listwithoutmain $'on:\n  push:\n    branches: [release/*]' 1 \
  "a branches list that never matches main does not count" \
  "push trigger does not reach main"
trigger_case glob $'on:\n  push:\n    branches: ["ma*"]' 0 \
  "a branches glob that matches main counts"
trigger_case ignoremain $'on:\n  push:\n    branches-ignore: [main]' 1 \
  "branches-ignore: [main] excludes the one branch that matters" \
  "push trigger does not reach main"
trigger_case ignoreother $'on:\n  push:\n    branches-ignore: [docs/**]' 0 \
  "branches-ignore that spares main still counts"
trigger_case negated $'on:\n  push:\n    branches: ["**", "!main"]' 1 \
  "a negated pattern AFTER a match takes main back out" \
  "push trigger does not reach main"
trigger_case renegated $'on:\n  push:\n    branches: ["!main", "**"]' 0 \
  "a positive pattern after a negation puts main back in"
trigger_case nullbranches $'on:\n  push:\n    branches:' 1 \
  "a branches: key whose every entry is commented out selects nothing" \
  "push trigger does not reach main"
trigger_case emptybranches $'on:\n  push:\n    branches: []' 1 \
  "an empty branches list selects nothing" \
  "push trigger does not reach main"
trigger_case bothfilters $'on:\n  push:\n    branches: [main]\n    branches-ignore: [docs/**]' 1 \
  "branches and branches-ignore together is an invalid trigger, not a passing one" \
  "both branches and branches-ignore"
trigger_case bothfiltersnull $'on:\n  push:\n    branches:\n    branches-ignore: [docs/**]' 1 \
  "a null branches: still counts as set, so the invalid combination is still caught" \
  "both branches and branches-ignore"
trigger_case tagsonly $'on:\n  push:\n    tags: ["v*"]' 1 \
  "a tags-only push trigger never fires on a branch push" \
  "push trigger does not reach main"
trigger_case scheduleonly $'on:\n  schedule:\n    - cron: "0 3 * * *"' 1 \
  "a nightly schedule is not the merge gate" \
  "runs on a schedule only"

# --------------------------------------------------------------- 11. empty tests/
# Without this the glob matches nothing, the loop body never runs, and the checker would report
# "0 suites, all wired" — a pass that means the opposite of what it says.
R="$WORK/empty"; scaffold "$R" alpha
rm -rf "$R/tests"; mkdir -p "$R/tests"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'refusing to report'; then
  ok "an empty tests/ refuses instead of passing vacuously"
else bad "expected refusal on an empty tests/; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 12. README names real directories
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

# --------------------------------------------------------------- 13. wired, but committed 100644
# #195. A suite whose step is invoked by a workflow that runs on a push to main — every rule above
# is satisfied — is still worthless if CI cannot execute the file. `git config core.filemode` is
# false on a Windows checkout, so `chmod +x` never reaches the INDEX and the suite is committed
# 100644; CI's `./tests/x/test.sh` then dies with "Permission denied", exit 126, on a commit this
# checker called fully enforced (PR #193). The working-copy mode set by scaffold()'s `chmod +x`
# above is a decoy here on purpose — it is what a Windows contributor's own working copy would also
# show, and it is not what CI reads.
R="$WORK/badmode"; scaffold "$R" alpha beta
sha=$(git -C "$R" hash-object -w "$R/tests/beta/test.sh")
git -C "$R" update-index --add --cacheinfo 100644,"$sha",tests/beta/test.sh
[ "$(git -C "$R" ls-files -s -- tests/beta/test.sh | awk '{print $1}')" = 100644 ] \
  || bad "fixture bug: tests/beta/test.sh was not restaged at 100644"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'tests/beta/test.sh' \
   && printf '%s' "$out" | grep -q '100644' \
   && printf '%s' "$out" | grep -q 'git update-index --chmod=+x tests/beta/test.sh'; then
  ok "a suite committed 100644 is refused, naming the mode and the remedy"
else bad "expected refusal naming tests/beta/test.sh, its mode and the remedy; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 14. the happy path stays a pass
# The companion to 13: this same probe must not turn the ordinary 100755 case scaffold() now
# builds into an accidental refusal. Section 1 already covers the real repo; this pins the shape
# a scratch fixture produces, so the guarantee survives an unrelated edit to scaffold() itself.
R="$WORK/goodmode"; scaffold "$R" alpha beta
out=$(run_check "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "suites staged 100755 are not reported as inexecutable"
else bad "expected acceptance for a normally-staged fixture; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 15. not a git repository at all
# The mode is unknowable here, not merely "not 100755" — a directory with no `.git` cannot answer
# `git ls-files -s`. Reporting every suite as fine would be the exact failure this issue closes,
# one layer further down: an unanswerable question read as a pass. `worktrees-ignored.sh` applies
# the same rule to its own verdict.
R="$WORK/notarepo"; scaffold "$R" alpha
rm -rf "$R/.git"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -qi 'index'; then
  ok "a directory that is not a git repository refuses rather than reporting every suite fine"
else bad "expected refusal naming the unreadable index; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 16. a suite committed as a symlink
# `120000` is not `100644` — the "wrong mode" case above would not catch it by accident — and CI
# would follow the link rather than refuse it outright. The kit ships no symlinked suite; accepting
# a mode nobody intended is how the next hole opens, so this is refused on the same footing as an
# ordinary non-executable file.
R="$WORK/symlink"; scaffold "$R" alpha
sha=$(git -C "$R" hash-object -w "$R/tests/alpha/test.sh")
git -C "$R" update-index --add --cacheinfo 120000,"$sha",tests/alpha/test.sh
[ "$(git -C "$R" ls-files -s -- tests/alpha/test.sh | awk '{print $1}')" = 120000 ] \
  || bad "fixture bug: tests/alpha/test.sh was not restaged at 120000"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'tests/alpha/test.sh' \
   && printf '%s' "$out" | grep -q '120000'; then
  ok "a suite committed as a symlink (120000) is refused"
else bad "expected refusal naming tests/alpha/test.sh and mode 120000; got rc=$rc: $out"; fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ci-wiring golden test: all sections passed."
else
  echo "ci-wiring golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
