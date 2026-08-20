#!/usr/bin/env bash
# guarded-pr-merge.sh — merge a PR on GitHub, then decide the outcome from `gh pr view`'s
# `state`, never from `gh pr merge`'s own exit code (#184).
#
# `gh pr merge` does two unrelated things: it merges the PR **on GitHub**, then tidies up
# **locally** (check the base branch out, delete the merged head branch). One exit code covers
# both, so it can never say which half failed — and the local half fails on this kit's *normal*
# layout, not an exotic one: `implement-issue` gives every issue its own worktree, so the base
# branch is usually already checked out somewhere else, and gh's post-merge `git checkout`/branch
# delete then fails with a non-zero exit even though the merge landed. `merge-pr` Step 5 already
# reads the PR back for this reason ("The exit code doesn't decide — GitHub's state does", #178);
# this script is the one home for that decision, so a second caller (the auto-dev supervisor's
# takeover merge, #184) cannot carry its own — divergent — copy of the same table.
#
# The OPEN case needs a SECOND signal, not just `state`: on a repo with a merge queue, a
# successful enqueue exits 0 and leaves the PR `OPEN` until the queue lands it later, which looks
# identical to a genuine rejection if you only look at `state`. So this script also remembers
# whether the `gh pr merge` call itself exited 0, and uses that to tell the two apart.
#
# Usage:
#   guarded-pr-merge.sh [-R <owner/repo>] <PR-number> [-- <gh pr merge args…>]
#
#   -R <owner/repo>  passed to both `gh pr merge` and `gh pr view` — needed when this runs
#                    outside a git checkout of the target repo (gh cannot infer it then).
#   <PR-number>      the pull request to merge.
#   --               everything after it goes to `gh pr merge` verbatim. Defaults to
#                    `--squash --delete-branch` when omitted OR given with nothing after it —
#                    every caller in this kit wants squash-merge (enforced server-side here; see
#                    the repo profile), so there is no caller-visible difference between the two.
#
# Stdout carries EXACTLY one line, the verdict — safe for a caller to capture with
# `out=$(guarded-pr-merge.sh …)` and match verbatim. Every diagnostic, including `gh pr merge`'s
# own stderr, goes to this script's stderr instead; `gh pr merge`'s stdout is discarded rather
# than interleaved, so a status line gh happens to print there can never land ahead of the verdict.
#
# Exit codes — read the printed verdict line, not just the code, when scripting around this:
#   0  MERGED      — the merge landed on GitHub, whatever `gh pr merge`'s own exit code said.
#                    Prints `MERGED <merge-commit-sha>`. Local cleanup (branch/worktree teardown)
#                    is the caller's job, same as it always was — this script only decides.
#   1  QUEUED      — PR is still `OPEN`, but the merge call itself exited 0: a successful
#                    merge-queue enqueue, not a rejection. Prints `QUEUED`. Not landed yet; poll
#                    again later, do not retry the merge and do not treat this as a failure.
#   2  REJECTED    — PR is still `OPEN` and the merge call exited non-zero: a real rejection
#                    (failing required checks, conflicts, permissions, …). Prints `REJECTED` plus
#                    the merge call's stderr. Do not force-merge; surface it and stop.
#   3  CLOSED      — the PR was closed without merging. Prints `CLOSED`. Stop and ask — merging
#                    (or retrying a merge of) a deliberately closed PR is not a safe default.
#   4  UNCONFIRMED — the state readback itself did not answer after a few attempts, or answered
#                    with something this script does not recognise. Prints `UNCONFIRMED`. This is
#                    inconclusive, not a rejection: do not tear anything down (branch, worktree,
#                    worker slot) on this exit — re-run the readback later instead of guessing.
#   64 usage/precondition error (bad arguments, gh/jq missing, a bad env override) — nothing was
#                    attempted; stdout is empty. Deliberately its own code, distinct from every
#                    outcome above (in particular 2/REJECTED): a caller branching on the exit code
#                    alone must not read "I could not even try" as "GitHub said no".
set -euo pipefail

TOOL=guarded-pr-merge

usage() {
  echo "usage: $TOOL.sh [-R <owner/repo>] <PR-number> [-- <gh pr merge args…>]" >&2
}

refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

# Overridable so the golden suite (tests/guarded-pr-merge/test.sh) can exercise the UNCONFIRMED
# and retry paths without real sleeps; production callers get the defaults. Validated, not just
# defaulted: a bad override must refuse loudly (exit 64) rather than reach `sleep` or `[ -le ]`
# with a value neither can make sense of — a non-numeric READBACK_SLEEP previously reached `sleep`
# as the LAST command in an `&&` chain, where `set -e` treats its failure as the whole script's.
READBACK_ATTEMPTS="${GUARDED_PR_MERGE_READBACK_ATTEMPTS:-3}"
READBACK_SLEEP="${GUARDED_PR_MERGE_READBACK_SLEEP:-2}"
case "$READBACK_ATTEMPTS" in
  ''|*[!0-9]*) refuse "GUARDED_PR_MERGE_READBACK_ATTEMPTS must be a whole number, got '$READBACK_ATTEMPTS'" ;;
esac
[ "$READBACK_ATTEMPTS" -ge 1 ] || refuse "GUARDED_PR_MERGE_READBACK_ATTEMPTS must be at least 1, got '$READBACK_ATTEMPTS'"
case "$READBACK_SLEEP" in
  ''|*[!0-9]*) refuse "GUARDED_PR_MERGE_READBACK_SLEEP must be a whole number of seconds, got '$READBACK_SLEEP'" ;;
esac

REPO_FLAG=()
PR=""
MERGE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -R)        [ -n "${2:-}" ] || refuse "-R needs an <owner/repo>"
               REPO_FLAG=(-R "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; MERGE_ARGS=("$@"); break ;;
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$PR" ] || refuse "unexpected extra argument: $1 (gh pr merge args go after --)"
      PR="$1"; shift ;;
  esac
done

[ -n "$PR" ] || refuse "a PR number is required"
case "$PR" in
  ''|*[!0-9]*) refuse "'$PR' is not a PR number" ;;
esac

# No `--`, or `--` followed by nothing: both mean "no opinion", so both get the kit's default.
[ "${#MERGE_ARGS[@]}" -eq 0 ] && MERGE_ARGS=(--squash --delete-branch)

command -v gh > /dev/null 2>&1 || refuse "gh is missing — this script has no way to merge a PR without it"
command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"

# ---------------------------------------------------------------- merge (exit code is a HINT,
# not a verdict — kept only to disambiguate the OPEN case below, never trusted on its own)
#
# `${REPO_FLAG[@]+"${REPO_FLAG[@]}"}`, not a bare `"${REPO_FLAG[@]}"`: under `set -u`, bash 3.2
# (still `/bin/bash` on stock macOS) treats an empty array's `[@]` expansion as an unbound
# variable — the same pitfall already fixed this way in guarded-commit.sh/guarded-merge.sh.
# REPO_FLAG is empty on every documented call in this kit (no caller passes -R), so this is the
# routine case, not an edge one.
#
# stdout is discarded (`>/dev/null`) so a status line `gh pr merge` prints there can never land
# ahead of this script's own verdict on a caller's captured stdout. stderr is captured via the
# `2>&1 1>/dev/null` swap inside the command substitution — no temp file, so nothing to clean up
# on an early exit either.
set +e
merge_err=$(gh pr merge "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} "${MERGE_ARGS[@]}" 2>&1 1>/dev/null)
merge_rc=$?
set -e

# ---------------------------------------------------------------- read GitHub's state back
attempt=1
state=""
merged_at=""
merge_sha=""
while [ "$attempt" -le "$READBACK_ATTEMPTS" ]; do
  set +e
  view_json=$(gh pr view "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} \
    --json state,mergedAt,mergeCommit --jq '[.state, (.mergedAt // ""), (.mergeCommit.oid // "")] | @tsv' 2>/dev/null)
  view_rc=$?
  set -e
  if [ "$view_rc" -eq 0 ] && [ -n "$view_json" ]; then
    # One `jq` call above already reduced the readback to a single TSV line; `IFS=$'\t' read`
    # splits it locally with no further subprocess. `read` itself can fail (e.g. no trailing
    # newline on some shells) — `set +e` around it, same reasoning as the old per-field jq calls
    # it replaces: a malformed line is one more failed attempt, not a `set -e` abort.
    set +e
    IFS=$'\t' read -r state merged_at merge_sha <<< "$view_json"
    set -e
    [ -n "$state" ] && break
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -le "$READBACK_ATTEMPTS" ]; then
    sleep "$READBACK_SLEEP"
  fi
done

if [ -z "$state" ]; then
  echo "$TOOL: UNCONFIRMED — gh pr view did not answer after $READBACK_ATTEMPTS attempts." >&2
  echo "       gh pr merge exited $merge_rc; nothing here says whether it landed. Do not tear" >&2
  echo "       anything down on this — re-run the readback later instead of guessing." >&2
  echo "UNCONFIRMED"
  exit 4
fi

case "$state" in
  MERGED)
    echo "$TOOL: MERGED — landed on GitHub (mergedAt=$merged_at), whatever gh pr merge's own" >&2
    echo "       exit code said (it was $merge_rc). Local cleanup is the caller's job." >&2
    # gh pr merge's stderr is worth reporting even on a landed merge: this is exactly the #184
    # shape (the local-cleanup half failing after the merge already succeeded), and this text is
    # what tells the reader WHICH collision it was.
    if [ "$merge_rc" -ne 0 ] && [ -n "$merge_err" ]; then
      echo "       gh pr merge's own stderr (informational — the merge landed regardless):" >&2
      printf '%s\n' "$merge_err" | sed 's/^/       /' >&2
    fi
    echo "MERGED ${merge_sha:-<unknown-sha>}"
    exit 0
    ;;
  OPEN)
    if [ "$merge_rc" -eq 0 ]; then
      echo "$TOOL: QUEUED — still OPEN, but gh pr merge exited 0: a successful merge-queue" >&2
      echo "       enqueue, not a rejection. Not landed yet — poll again later." >&2
      echo "QUEUED"
      exit 1
    else
      echo "$TOOL: REJECTED — still OPEN and gh pr merge exited $merge_rc:" >&2
      [ -n "$merge_err" ] && printf '%s\n' "$merge_err" | sed 's/^/       /' >&2
      echo "       Do not force-merge; surface this and stop." >&2
      echo "REJECTED"
      exit 2
    fi
    ;;
  CLOSED)
    echo "$TOOL: CLOSED — the PR was closed without merging while this ran." >&2
    echo "       Stop and ask; merging a deliberately closed PR is not a safe default." >&2
    echo "CLOSED"
    exit 3
    ;;
  *)
    echo "$TOOL: UNCONFIRMED — gh pr view returned an unrecognised state '$state'." >&2
    echo "       gh pr merge exited $merge_rc; do not tear anything down on this." >&2
    echo "UNCONFIRMED"
    exit 4
    ;;
esac
