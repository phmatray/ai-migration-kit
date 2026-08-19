#!/usr/bin/env bash
# Golden test for the merge gate's latest-run-per-job reduction (#91).
#
# The gate `merge-pr` applies is a jq program, and until this suite existed nothing ever ran it.
# It was wrong, in both directions, for the same reason: it read the check-runs on a head SHA as a
# FLAT SET, when GitHub gives a HISTORY PER JOB. Several runs of one job coexist on one SHA and
# only the newest is a verdict.
#
#   * Measured on PR #85: head sha 8c58eb2 carried three check-runs all named `kit` — a `cancelled`
#     superseded by the next push, then two `success`. The flat gate classified the PR as failed,
#     entered the corrections loop, found nothing to fix, and refused a PR that was green twice.
#     This repo's own ci.yml sets `cancel-in-progress` (#27/#29), so it produces that shape as a
#     matter of routine.
#   * The symmetric hazard, never yet exercised: a stale `success` from an earlier run sitting
#     beside a newer `failure` for the same job, where "some run succeeded" reads as fine. That is
#     the direction that merges something broken.
#
# One reduction fixes both, so one suite pins both — plus the carve-out that makes the fix safe: a
# job whose LATEST run is `cancelled` still blocks. A superseded cancellation and a real one (a
# human pressing Cancel, a timeout) are different events, and only the second is a verdict.
#
# The program under test is NOT copied here. It is EXTRACTED from the marked block inside
# skills/merge-pr/references/merge-mechanics.md §3 and run verbatim, so the thing this suite proves
# green is the thing an agent pastes. A second copy would drift, and a drifted copy of a gate is
# exactly the failure mode above wearing a passing test.
set -euo pipefail
cd "$(dirname "$0")/../.."

RECIPE="./skills/merge-pr/references/merge-mechanics.md"
[ -r "$RECIPE" ] || { echo "FAIL: $RECIPE missing — nothing to extract the gate from"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72). KIT_ROOT is derived from this
# file's location rather than $PWD — $PWD is only right because a `cd` sits above it.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)
FIXTURES="$KIT_ROOT/tests/merge-gate/fixtures"

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and the gate"
  echo "      this suite exercises is written in it."
  exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

# ------------------------------------------------------------------ 1. extract the shipped program
#
# The markers are jq comments, so they can sit inside the program without changing it, and the
# recipe stays a single pasteable block. Both are matched as fixed strings.
BEGIN_MARK='# >>> merge-gate verdict'
END_MARK='# <<< merge-gate verdict'

n_begin=$(grep -c -F -- "$BEGIN_MARK" "$RECIPE" || true)
n_end=$(grep -c -F -- "$END_MARK" "$RECIPE" || true)
if [ "$n_begin" != "1" ] || [ "$n_end" != "1" ]; then
  echo "FAIL: $RECIPE must carry EXACTLY ONE marked verdict program"
  echo "      found $n_begin '$BEGIN_MARK' and $n_end '$END_MARK'"
  echo "      Two blocks means two homes for the gate, and a gate with two homes drifts."
  exit 1
fi

PROG="$WORK/verdict.jq"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { inside = 1 }
  inside       { print }
  inside && index($0, e) { exit }
' "$RECIPE" > "$PROG"

[ -s "$PROG" ] || { echo "FAIL: extracted an empty program from $RECIPE"; exit 1; }

# The block lives inside a shell `jq '...'` single-quoted string in the recipe. A single quote
# anywhere in it would terminate that string early, so the snippet an agent pastes would not be the
# snippet tested here — it would not even run. Cheap to check, invisible when it breaks.
if grep -q "'" "$PROG"; then
  note_fail "the verdict program contains a single quote, which would close the jq '...' string it
      is pasted inside. Rewrite the offending line without one."
fi

# jq compiles the whole program before it reads any input, so empty input is a pure parse check.
if ! jq -f "$PROG" < /dev/null > /dev/null 2>"$WORK/parse.err"; then
  echo "FAIL: the extracted verdict program does not compile:"
  sed 's/^/      /' "$WORK/parse.err"
  exit 1
fi

# The pagination note is load-bearing and easy to lose in a rewrite: without --paginate --slurp the
# gate judges the first page and calls a PR green on the strength of the checks it happened to see.
grep -q -F -- '--paginate --slurp' "$RECIPE" || \
  note_fail "$RECIPE no longer pipes the check-runs through \`--paginate --slurp\` — the gate would
      judge one page of a multi-page SHA."

# ------------------------------------------------------------------------------- 2. the verdicts
#
# verdict <fixture> <latest-count> <failed-jobs> <pending-jobs> <what it pins>
# Job lists are space-joined and sorted; `-` means none.
verdict() {
  local fixture="$1" want_latest="$2" want_failed="$3" want_pending="$4" what="$5"
  local path="$FIXTURES/$fixture" out got_latest got_failed got_pending
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  if ! out=$(jq -f "$PROG" < "$path" 2>"$WORK/run.err"); then
    note_fail "$fixture — the verdict program errored ($what):
$(sed 's/^/      /' "$WORK/run.err")"
    return 0
  fi
  got_latest=$(printf '%s' "$out" | jq '.latest | length')
  got_failed=$(printf '%s' "$out" | jq -r '[.failed[].name] | sort | join(" ")')
  got_pending=$(printf '%s' "$out" | jq -r '[.pending[].name] | sort | join(" ")')
  [ -n "$got_failed" ] || got_failed='-'
  [ -n "$got_pending" ] || got_pending='-'
  if [ "$got_latest" != "$want_latest" ] || [ "$got_failed" != "$want_failed" ] \
     || [ "$got_pending" != "$want_pending" ]; then
    note_fail "$fixture — $what
      want: latest=$want_latest failed=$want_failed pending=$want_pending
      got:  latest=$got_latest failed=$got_failed pending=$got_pending"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# The measured #85 shape: three `kit` runs on one SHA, the first superseded by the next push. The
# flat gate refused this PR; the reduction lets it through, because the latest run of every job is
# a success.
verdict superseded-cancel.json 2 - - \
  'a superseded cancelled run does not block a job whose latest run succeeded'

# The carve-out. Weakening the gate into "ignore cancelled" would pass this, which is why it is
# here: a real cancellation — a human pressing Cancel, a timeout — is a non-verdict and must block.
verdict latest-cancelled.json 1 kit - \
  'a job whose LATEST run is cancelled still blocks'

# The direction that would actually merge something broken.
verdict stale-success.json 1 kit - \
  'a stale success does not mask a newer failure for the same job'

# Unchanged behaviour, restated as a fixture so a rewrite cannot quietly alter it.
verdict skipped-only.json 1 - - \
  'a skipped run stays a non-event — neither failed nor pending'

# No CI at all: the reduction must not invent a verdict. The caller falls back to mergeStateStatus.
verdict no-checks.json 0 - - \
  'zero check-runs reduce to zero jobs, so nothing is failed or pending'

# Two runs of one job starting in the same second. Order in the API response is NOT a tiebreak —
# both fixtures list the loser last, so a reduction that took the array tail would answer wrongly
# in one direction and right-by-accident in the other. Greatest id decides, deterministically.
verdict tie-greatest-id-blocks.json 1 kit - \
  'on a started_at tie the greatest id wins — here a failure, despite a success later in the array'
verdict tie-greatest-id-passes.json 1 - - \
  'on a started_at tie the greatest id wins — here a success, despite a failure later in the array'

# `pending` is derived from the same reduced set: an older success must not retire a running job.
verdict latest-in-progress.json 1 - kit \
  'a job whose latest run is still in progress is pending, not green'

# Several jobs at once, across two pages of --slurp output, including a job that no longer runs:
# `legacy-suite` has only an old failure, and absence of a current run is not a pass.
verdict multi-job-paginated.json 3 legacy-suite - \
  'jobs are reduced independently, across pages, and a vanished job keeps blocking'

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "merge-gate: FAILED"
  exit 1
fi
echo
echo "merge-gate: OK — the shipped verdict program judges the latest run of each job."
