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
#                    `--squash --delete-branch` when omitted, matching every caller in this kit
#                    (squash-merge is enforced server-side here; see the repo profile).
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
#   4  UNCONFIRMED — the state readback itself did not answer after a few attempts. Prints
#                    `UNCONFIRMED`. This is inconclusive, not a rejection: do not tear anything
#                    down (branch, worktree, worker slot) on this exit — re-run the readback
#                    later instead of guessing.
#   *  usage error (missing PR number, etc.) — nothing was attempted.
set -euo pipefail

TOOL=guarded-pr-merge
# Overridable so the golden suite (tests/guarded-pr-merge/test.sh) can exercise the UNCONFIRMED
# path without three real sleeps; production callers get the defaults.
READBACK_ATTEMPTS="${GUARDED_PR_MERGE_READBACK_ATTEMPTS:-3}"
READBACK_SLEEP="${GUARDED_PR_MERGE_READBACK_SLEEP:-2}"

usage() {
  echo "usage: $TOOL.sh [-R <owner/repo>] <PR-number> [-- <gh pr merge args…>]" >&2
}

REPO_FLAG=()
PR=""
MERGE_ARGS=()
HAVE_MERGE_ARGS=0

while [ $# -gt 0 ]; do
  case "$1" in
    -R)        [ -n "${2:-}" ] || { echo "$TOOL: -R needs an <owner/repo>" >&2; usage; exit 2; }
               REPO_FLAG=(-R "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; HAVE_MERGE_ARGS=1; MERGE_ARGS=("$@"); break ;;
    -*)        echo "$TOOL: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      [ -z "$PR" ] || { echo "$TOOL: unexpected extra argument: $1 (gh pr merge args go after --)" >&2; usage; exit 2; }
      PR="$1"; shift ;;
  esac
done

[ -n "$PR" ] || { echo "$TOOL: a PR number is required" >&2; usage; exit 2; }
case "$PR" in
  ''|*[!0-9]*) echo "$TOOL: '$PR' is not a PR number" >&2; usage; exit 2 ;;
esac

if [ "$HAVE_MERGE_ARGS" -eq 0 ] || [ "${#MERGE_ARGS[@]}" -eq 0 ]; then
  MERGE_ARGS=(--squash --delete-branch)
fi

command -v gh > /dev/null 2>&1 || {
  echo "$TOOL: gh is missing — it is a \`recommended\` prerequisite in requirements.json, required" >&2
  echo "       by this script" >&2
  exit 2
}
command -v jq > /dev/null 2>&1 || {
  echo "$TOOL: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

# ---------------------------------------------------------------- merge (exit code is a HINT,
# not a verdict — kept only to disambiguate the OPEN case below, never trusted on its own)
merge_err_file=$(mktemp 2>/dev/null) || merge_err_file=""
set +e
if [ -n "$merge_err_file" ]; then
  gh pr merge "$PR" "${REPO_FLAG[@]}" "${MERGE_ARGS[@]}" 2>"$merge_err_file"
else
  gh pr merge "$PR" "${REPO_FLAG[@]}" "${MERGE_ARGS[@]}" 2>&1
fi
merge_rc=$?
set -e
merge_err=""
if [ -n "$merge_err_file" ]; then
  merge_err=$(cat -- "$merge_err_file" 2>/dev/null || true)
  rm -f -- "$merge_err_file"
fi

# ---------------------------------------------------------------- read GitHub's state back
attempt=1
state=""
merged_at=""
merge_sha=""
while [ "$attempt" -le "$READBACK_ATTEMPTS" ]; do
  set +e
  view_json=$(gh pr view "$PR" "${REPO_FLAG[@]}" \
    --json state,mergedAt,mergeCommit --jq '{state, mergedAt, mergeCommit: (.mergeCommit.oid // "")}' 2>/dev/null)
  view_rc=$?
  set -e
  if [ "$view_rc" -eq 0 ] && [ -n "$view_json" ]; then
    # `set +e` around the parse too: a malformed/non-JSON view_json (a wrapper on $PATH mangling
    # output, a truncated response) must be one more failed attempt, not a jq exit propagated
    # through `set -e` that kills this script instead of falling through to UNCONFIRMED below.
    set +e
    state=$(printf '%s' "$view_json" | jq -r '.state // empty' 2>/dev/null)
    merged_at=$(printf '%s' "$view_json" | jq -r '.mergedAt // empty' 2>/dev/null)
    merge_sha=$(printf '%s' "$view_json" | jq -r '.mergeCommit // empty' 2>/dev/null)
    set -e
    [ -n "$state" ] && break
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -le "$READBACK_ATTEMPTS" ] && sleep "$READBACK_SLEEP"
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
