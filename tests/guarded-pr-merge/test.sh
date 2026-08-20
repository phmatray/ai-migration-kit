#!/usr/bin/env bash
# Golden test for guarded-pr-merge.sh — the shared decision `merge-pr` Step 5 and the auto-dev
# supervisor's takeover branch both call after a `gh pr merge` (#184).
#
# The bug this closes: `gh pr merge` does two unrelated things — merge on GitHub, then tidy up
# LOCALLY (checkout the base branch, delete the head branch) — under one exit code. On this kit's
# normal layout (every issue in its own worktree) the local half routinely fails even though the
# merge landed, so a caller that trusts the exit code sees a "failed" takeover for a PR GitHub
# already reports MERGED. `merge-pr` Step 5 was fixed for this in #178; the auto-dev supervisor's
# takeover carried its own inline copy and was not, so the same misread survived in the one place
# #178 named as its worst consequence (never freeing a stalled fleet slot). guarded-pr-merge.sh is
# now the one home for the decision, so both callers read it the same way.
#
# A stub `gh` on PATH stands in for both `gh pr merge` and `gh pr view`, modelled on
# tests/tick-plan/test.sh's stub (the kit's existing precedent for testing a script that calls gh
# without touching the network): it never runs on real GitHub, so every fixture below is
# deterministic and offline.
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRIPT="./skills/merge-pr/scripts/guarded-pr-merge.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and the"
  echo "      script this suite exercises is written against it."
  exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

# A `gh` stub on PATH. `pr merge` and `pr view` are the only two subcommands this script ever
# calls; every other invocation is a test bug and fails loudly rather than silently doing nothing.
#
#   GH_MERGE_RC          exit code `gh pr merge` returns (default 0)
#   GH_MERGE_STDERR       one line it writes to stderr first (default: none)
#   GH_VIEW_MODE          ok (default) | fail | bad-json
#   GH_VIEW_RC            exit code `gh pr view` returns when GH_VIEW_MODE=fail (default 1)
#   GH_VIEW_FAIL_FIRST_N  how many leading `pr view` calls fail (GH_VIEW_MODE=fail) before the
#                         configured mode takes over — proves the retry loop actually retries,
#                         not just that it eventually gives up (default 0)
#   GH_VIEW_STATE/GH_VIEW_MERGED_AT/GH_VIEW_SHA   the PR fields to report once view succeeds
#   GH_VIEW_COUNT_FILE    scratch file this stub uses to count its own `pr view` calls
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  [ -n "${GH_MERGE_STDERR:-}" ] && echo "$GH_MERGE_STDERR" >&2
  exit "${GH_MERGE_RC:-0}"
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  count=0
  [ -f "$GH_VIEW_COUNT_FILE" ] && count=$(cat "$GH_VIEW_COUNT_FILE")
  count=$((count + 1))
  echo "$count" > "$GH_VIEW_COUNT_FILE"
  if [ "$count" -le "${GH_VIEW_FAIL_FIRST_N:-0}" ]; then
    exit "${GH_VIEW_RC:-1}"
  fi
  case "${GH_VIEW_MODE:-ok}" in
    fail)     exit "${GH_VIEW_RC:-1}" ;;
    bad-json) printf 'not json, a wrapper on PATH mangled this\n' ;;
    *)        printf '{"state":"%s","mergedAt":"%s","mergeCommit":"%s"}\n' \
                "${GH_VIEW_STATE:-}" "${GH_VIEW_MERGED_AT:-}" "${GH_VIEW_SHA:-}" ;;
  esac
else
  echo "gh stub: unexpected invocation: $*" >&2
  exit 99
fi
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# Fast and deterministic: production defaults to 3 attempts / 2s apart, which would make the
# UNCONFIRMED and retry-recovery fixtures below take 4-6s each for no more signal.
export GUARDED_PR_MERGE_READBACK_ATTEMPTS=3
export GUARDED_PR_MERGE_READBACK_SLEEP=0

# run_case <name> <want-exit> <want-stdout> <what> [script-args…] -- reads every GH_* var already
# exported by the caller, so each fixture below sets exactly the ones its scenario needs and
# leaves the rest at their (unset-means-default) value. script-args defaults to a normal
# `<PR> -- --squash --delete-branch` invocation; the usage-error case overrides it to omit the PR.
run_case() {
  local name="$1" want_rc="$2" want_stdout="$3" what="$4"; shift 4
  local out_file="$WORK/stdout.$name" err_file="$WORK/stderr.$name" rc got_stdout
  export GH_CALL_LOG="$WORK/gh-calls.$name.log"
  export GH_VIEW_COUNT_FILE="$WORK/view-count.$name"
  : > "$GH_CALL_LOG"
  rm -f "$GH_VIEW_COUNT_FILE"

  if [ "$#" -eq 0 ]; then
    set -- 999 -- --squash --delete-branch
  fi

  set +e
  "$SCRIPT" "$@" > "$out_file" 2> "$err_file"
  rc=$?
  set -e
  got_stdout=$(cat "$out_file")

  if [ "$rc" -ne "$want_rc" ]; then
    note_fail "$name — $what
      want exit $want_rc, got $rc
      stdout: $got_stdout
      stderr:
$(sed 's/^/        /' "$err_file")"
    return 0
  fi
  if [ "$got_stdout" != "$want_stdout" ]; then
    note_fail "$name — $what
      want stdout '$want_stdout', got '$got_stdout'"
    return 0
  fi
  echo "ok: $name — $what"
}

# ------------------------------------------------------------------------------- 1. MERGED, clean
#
# gh pr merge exits 0 and state is already MERGED — the ordinary, uncontested case.
GH_MERGE_RC=0 GH_MERGE_STDERR="" GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 \
GH_VIEW_STATE=MERGED GH_VIEW_MERGED_AT=2026-08-20T00:00:00Z GH_VIEW_SHA=cafef00d \
run_case clean-merge 0 "MERGED cafef00d" \
  'gh pr merge exits 0 and state MERGED -> MERGED, exit 0'

# ------------------------------------------------------ 2 & 3. the two documented #184 collisions
#
# Both are the exact stderr text the issue quotes: a non-zero merge exit from LOCAL cleanup gh
# could not finish, on a merge that landed on GitHub regardless. This is the defect the takeover
# branch shipped with — state must win over the exit code in both directions.
GH_MERGE_RC=1 GH_MERGE_STDERR="failed to run git: fatal: 'main' is already used by worktree at '/x/ai-migration-kit'" \
GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 GH_VIEW_STATE=MERGED GH_VIEW_MERGED_AT=2026-08-20T00:00:00Z GH_VIEW_SHA=deadbeef \
run_case collision-main-checked-out 0 "MERGED deadbeef" \
  "gh pr merge exits non-zero on 'main is already used by worktree', but state is MERGED -> MERGED, exit 0 (not the non-zero exit code)"

GH_MERGE_RC=1 GH_MERGE_STDERR="failed to delete local branch fix/1-x: used by worktree at '/x'" \
GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 GH_VIEW_STATE=MERGED GH_VIEW_MERGED_AT=2026-08-20T00:00:00Z GH_VIEW_SHA=beadfeed \
run_case collision-branch-checked-out 0 "MERGED beadfeed" \
  "gh pr merge exits non-zero on 'failed to delete local branch … used by worktree', but state is MERGED -> MERGED, exit 0"

# ------------------------------------------------------------------------- 4. OPEN, real rejection
#
# gh pr merge itself exited non-zero (a required check failing, a conflict, no permission) and the
# PR is still OPEN: a genuine rejection, not a queue enqueue.
GH_MERGE_RC=1 GH_MERGE_STDERR="a required status check has not passed" \
GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 GH_VIEW_STATE=OPEN GH_VIEW_MERGED_AT="" GH_VIEW_SHA="" \
run_case open-rejected 2 "REJECTED" \
  'gh pr merge exits non-zero and state stays OPEN -> REJECTED, exit 2 (a real rejection)'

# --------------------------------------------------------------------- 5. OPEN, merge-queue enqueue
#
# gh pr merge exits 0 (a successful enqueue) and the PR is still OPEN until the queue lands it.
# The only signal that tells this apart from case 4 is the merge call's own exit code.
GH_MERGE_RC=0 GH_MERGE_STDERR="" \
GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 GH_VIEW_STATE=OPEN GH_VIEW_MERGED_AT="" GH_VIEW_SHA="" \
run_case open-queued 1 "QUEUED" \
  'gh pr merge exits 0 and state stays OPEN -> QUEUED, exit 1 (merge-queue enqueue, not a rejection)'

# ------------------------------------------------------------------------------------- 6. CLOSED
#
# The PR was closed without merging while this ran (or before it started) — a deliberate act to
# never paper over, whatever the merge call's own exit code said.
GH_MERGE_RC=1 GH_MERGE_STDERR="pull request is closed" \
GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 GH_VIEW_STATE=CLOSED GH_VIEW_MERGED_AT="" GH_VIEW_SHA="" \
run_case closed 3 "CLOSED" \
  'state CLOSED -> CLOSED, exit 3, regardless of the merge call exit code'

# --------------------------------------------------------------------- 7. permanently unreadable
#
# Every gh pr view attempt fails outright — a genuinely inconclusive readback. Must NOT be reported
# as MERGED, OPEN or CLOSED; the caller has to be told to re-check later, not to guess.
GH_MERGE_RC=1 GH_MERGE_STDERR="network blip" \
GH_VIEW_MODE=fail GH_VIEW_RC=1 GH_VIEW_FAIL_FIRST_N=0 \
run_case unreadable 4 "UNCONFIRMED" \
  'gh pr view fails on every attempt -> UNCONFIRMED, exit 4 (inconclusive, not a rejection)'

# ---------------------------------------------------------------------------- 8. malformed output
#
# gh pr view exits 0 but the payload is not JSON (a wrapper on PATH, a truncated response). Must
# not crash the script under set -e (the defect this suite's own authoring caught) and must not
# be misread as any real state — it is exactly as inconclusive as an outright failure.
GH_MERGE_RC=0 GH_MERGE_STDERR="" \
GH_VIEW_MODE=bad-json GH_VIEW_FAIL_FIRST_N=0 \
run_case malformed-view 4 "UNCONFIRMED" \
  'gh pr view exits 0 with non-JSON output -> UNCONFIRMED, exit 4, and the script does not abort'

# ----------------------------------------------------------------------- 9. retry actually retries
#
# The first two gh pr view calls fail and the third succeeds — proves the retry loop recovers a
# transient failure instead of only ever hitting the "give up" path exercised above.
GH_MERGE_RC=0 GH_MERGE_STDERR="" \
GH_VIEW_MODE=ok GH_VIEW_RC=1 GH_VIEW_FAIL_FIRST_N=2 \
GH_VIEW_STATE=MERGED GH_VIEW_MERGED_AT=2026-08-20T00:00:00Z GH_VIEW_SHA=1234567 \
run_case retry-recovers 0 "MERGED 1234567" \
  'the first 2 of 3 allowed gh pr view attempts fail, the 3rd succeeds -> MERGED, exit 0'
attempts=$(cat "$WORK/view-count.retry-recovers" 2>/dev/null || echo 0)
[ "$attempts" -eq 3 ] || note_fail "retry-recovers — expected exactly 3 gh pr view attempts, saw $attempts"

# ------------------------------------------------------------------------------ 10. usage errors
#
# No PR number: nothing should be attempted at all — neither gh subcommand runs.
GH_MERGE_RC=0 GH_MERGE_STDERR="" GH_VIEW_MODE=ok GH_VIEW_FAIL_FIRST_N=0 GH_VIEW_STATE=MERGED \
run_case no-pr-arg 2 "" 'no PR number given -> refuses (exit 2), no gh call' -- --squash --delete-branch
if [ -s "$WORK/gh-calls.no-pr-arg.log" ]; then
  note_fail "no-pr-arg — refused but still called gh:
$(sed 's/^/    /' "$WORK/gh-calls.no-pr-arg.log")"
fi

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "guarded-pr-merge: FAILED"
  exit 1
fi
echo
echo "guarded-pr-merge: OK — the takeover decision reads GitHub's state, never gh pr merge's exit code."
