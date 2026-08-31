#!/usr/bin/env bash
# base-run-verdict.sh — read the base branch's CI verdict AT THE SHA a merge just produced (#355).
#
# WHY THIS EXISTS. `merge-pr` gates hard on CI *before* the merge and then tears down at PR-green:
# Step 5 merges, Step 6 files follow-ups, Step 7 deletes the branch, Step 8 reports. Nothing in
# that tail ever looks at the workflow run the merge itself triggers on the base branch — so a
# green PR check-run, which only ever proved the branch was green against the base it was TESTED
# with, is allowed to stand in for "the tree this merge produced is green". Two PRs each green
# against their own base can still break `main` when both land.
#
# Measured on this repo, 2026-08-30: `dce7d5b` (#338) had its push run on `main` CANCELLED,
# superseded 2m39s later by the next merge; `f17c85c` (#342) had run 33346395704 record the
# failure. Both PRs had already reported MERGED and torn down, so neither run was ever read. `main`
# stayed red ~40 minutes and every in-flight PR in the fleet inherited the red bar — PR #340's own
# CI failed on it despite its diff being unrelated. A human noticed; #352 was filed by hand.
#
# WHAT IT DOES. Given the squash sha `guarded-pr-merge.sh` printed on exit 0, it resolves the
# check-runs FOR THAT SHA, polls while any of them is still running (bounded), and hands the final
# set to the registered decision `ci.verdict` — the same reduction `merge-pr` Step 3 already runs.
# It prints one JSON object and exits 0.
#
#   {"verdict":"green|red|unverified","reason":"<slug>","sha":"<sha>","runs":[{name,html_url,state}]}
#
# BY SHA, NEVER BY RECENCY. `gh run list --branch main` answers "the newest run on the branch",
# which under a merge train — the normal `auto-dev` shape — is routinely a SIBLING merge's run
# landing seconds later. That would attribute someone else's red to this merge, and someone else's
# green over this merge's red. The check-runs endpoint is keyed on the sha by construction, which
# is why it is the one asked here (and it is the same endpoint §3 already uses). Nothing in this
# script asks a recency-shaped question; `tests/merge-base-ci/test.sh` arms a deliberately wrong
# `gh run list` answer so a rewrite that reaches for one goes red.
#
# THE VERDICT MAPPING. `ci.verdict` answers a PRE-merge question, so its four words do not map
# one-to-one onto a POST-merge report. This script maps them; it does not re-decide them, and it
# adds no second rule set (#208 — one id, one program, one home):
#
#   clear   -> green       reason "clear"
#   failed  -> red         reason "failed"      ... unless every failing job's latest run is
#              unverified  reason "cancelled"       `cancelled`, which is a NON-VERDICT, not a
#                                                   pass and not a breakage. `cancel-in-progress`
#                                                   (#27/#29) cancels the previous `main` run the
#                                                   moment the next merge lands, so under a fleet
#                                                   this is the COMMON outcome — it is exactly the
#                                                   `dce7d5b` case above, and the honest answer is
#                                                   "this merge's effect was never verified".
#   pending -> keep polling; on timeout, unverified, reason "timeout"
#   no-ci   -> unverified  reason "no-ci"       the base runs no CI on push, or the run has not
#                                               been posted yet. Pre-merge that means "let
#                                               mergeStateStatus decide"; post-merge the merge has
#                                               already happened and there is nothing to decide —
#                                               reporting it green is the regression #355 exists
#                                               to prevent.
#
# A TIMEOUT IS NOT A BREAKAGE. On expiry the answer is `unverified`, never `red`: a skill that
# reported a slow run as a failure would file bugs against healthy merges. And an `unverified` is
# not this script failing — it is this script working, and saying so.
#
# IT ALWAYS ANSWERS. Exit is 0 for every verdict, including every non-verdict. `merge-pr` calls
# this AFTER the merge has landed and cannot be undone, so a non-zero exit here would give an
# autonomous fleet a brand-new way to strand a slot on a merge that already succeeded. The only
# refusal is a usage error (exit 64), where there is no sha to resolve and printing `unverified`
# would let a caller that forgot its argument report a clean non-verdict forever.
#
# IT NEVER REVERTS, and this script cannot: it performs no writes at all. On red the caller files
# a bug naming the sha and the run URL (`merge-pr` Step 5b). An autonomous revert of what may well
# be a sibling merge's breakage is a strictly worse failure than a filed issue.
#
# Exit codes:
#   0   a verdict was produced — `green`, `red`, or one of the `unverified` non-verdicts
#   64  usage error: no sha, an unparseable option, a non-numeric bound
set -euo pipefail

TOOL="base-run-verdict"

usage() {
  echo "usage: $TOOL.sh [-R <owner/repo>] <base-sha> [--timeout <seconds>] [--poll-seconds <seconds>]" >&2
}
refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

# ------------------------------------------------------------------------------ 1. self-location
#
# $0 through any symlinks first — a plugin install reaches this file by link, and `pwd -P` alone
# canonicalizes the directory, not the link. No `readlink -f`: macOS's readlink has no -f. Lifted
# from scripts/decide.sh, which lifted it from guarded-commit.sh, where the loop was debugged.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
  || KIT_ROOT="$(dirname -- "$SELF")/../../.."
DECIDE="$KIT_ROOT/scripts/decide.sh"

# ------------------------------------------------------------------------------ 2. the arguments
SHA=""
REPO=""
TIMEOUT=600
POLL_SECONDS=15

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    -R|--repo)      REPO="${2:-}"; [ -n "$REPO" ] || refuse "-R needs an <owner/repo>"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-}"; is_uint "$TIMEOUT" || refuse "--timeout needs a whole number of seconds, got '${2:-}'"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="${2:-}"; is_uint "$POLL_SECONDS" || refuse "--poll-seconds needs a whole number of seconds, got '${2:-}'"; shift 2 ;;
    --)             shift ;;
    -*)             refuse "unexpected option: $1" ;;
    *)
      [ -z "$SHA" ] || refuse "two shas given: '$SHA' and '$1' — one merge produces one sha"
      SHA="$1"; shift ;;
  esac
done

[ -n "$SHA" ] || refuse "no base sha given (guarded-pr-merge.sh prints it as \`MERGED <sha>\` on exit 0)"
case "$SHA" in
  *[!0-9a-fA-F]*|"") refuse "'$SHA' is not a hex sha" ;;
esac

command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"
command -v gh > /dev/null 2>&1 || refuse "gh is missing — there is no other way to read check-runs"
[ -x "$DECIDE" ] || refuse "cannot execute $DECIDE — the ci.verdict decision has no other home"

# `{owner}/{repo}` is gh's own placeholder, resolved from the repository gh is pointed at. An
# explicit -R overrides it, which is what lets a caller standing in a worktree of one repo read
# another's base branch.
OWNER_REPO="{owner}/{repo}"
[ -n "$REPO" ] && OWNER_REPO="$REPO"

# ------------------------------------------------------------------------------- 3. the answer
#
# Printed through jq so the object is always valid JSON whatever the reason text holds, and always
# on ONE line: the caller reads it with `jq -r .verdict`, and a caller that captures it into a
# shell variable must not have to care about embedded newlines.
answer() {
  local verdict="$1" reason="$2" runs="${3:-[]}"
  jq -cn --arg v "$verdict" --arg r "$reason" --arg s "$SHA" --argjson runs "$runs" \
    '{verdict: $v, reason: $r, sha: $s, runs: $runs}'
  exit 0
}

# ------------------------------------------------------------------------------ 4. the poll loop
#
# `pending` is the only state worth waiting on. Everything else — a verdict, no CI at all, or a
# query that will not answer — is settled by the deadline the same way: what is true at the
# deadline is what gets reported.
#
# SECONDS is bash's own monotonic-ish counter of elapsed seconds since the shell started, so the
# deadline needs no `date` subprocess per poll and cannot be moved by a clock adjustment mid-run.
deadline=$(( SECONDS + TIMEOUT ))
last_reason="timeout"
verdict_json=""

while :; do
  raw=""
  rc=0
  # The two failures are kept apart deliberately. `gh` failing (rate limit, a network blip, an
  # unauthenticated host) is NOT evidence about the base branch, so it must not read as `no-ci`
  # — which is why it is retried until the deadline rather than answered on the first attempt.
  raw=$(gh api "repos/$OWNER_REPO/commits/$SHA/check-runs" --paginate --slurp 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    last_reason="query-failed"
  else
    dec_rc=0
    # `decide.sh` extracts and runs the marked `ci.verdict` block from
    # references/merge-mechanics.md §3 — the program `tests/merge-gate/test.sh` pins over
    # fixtures. Nothing is re-implemented here; a second copy of that reduction is precisely what
    # #208 removed.
    verdict_json=$(printf '%s' "$raw" | "$DECIDE" ci.verdict --json 2>/dev/null) || dec_rc=$?
    if [ "$dec_rc" -ne 0 ] || [ -z "$verdict_json" ]; then
      # The decision refusing is not the base branch's fault either — same treatment as a failed
      # query: retry, and if the deadline arrives first, say which of the two it was.
      last_reason="decision-failed"
    else
      ci=$(printf '%s' "$verdict_json" | jq -r '.verdict // ""')
      [ "$ci" = "pending" ] || break
      last_reason="timeout"
    fi
  fi
  [ "$SECONDS" -lt "$deadline" ] || answer unverified "$last_reason"
  # A zero poll interval is legitimate (the suites use it); `sleep 0` returns immediately.
  sleep "$POLL_SECONDS"
done

# ---------------------------------------------------------------------------- 5. map the verdict
#
# `.latest` is the REDUCED set — one run per job, newest wins — so this is the set a filed bug
# should name, not the raw history attached to the sha.
runs=$(printf '%s' "$verdict_json" \
  | jq -c '[ .latest[] | {name, html_url, state} ]')

case "$ci" in
  clear)
    answer green clear "$runs" ;;
  no-ci)
    answer unverified no-ci "$runs" ;;
  failed)
    # `ci.verdict` puts `cancelled` in `.failed` because pre-merge a cancelled check is a reason
    # NOT to merge. Post-merge it is a different fact: the merge already landed, and a cancelled
    # run recorded nothing about it. Split the two here rather than teaching the shared decision a
    # second, caller-specific meaning — the reduction has already dropped every SUPERSEDED
    # cancellation, so what reaches this point is only ever a job whose LATEST run was cancelled.
    n_real=$(printf '%s' "$verdict_json" \
      | jq '[ .failed[] | select(.state != "cancelled") ] | length')
    if [ "$n_real" -gt 0 ]; then
      answer red failed "$runs"
    fi
    answer unverified cancelled "$runs" ;;
  *)
    # `decide.sh` has already refused any word outside ci.verdict's declared vocabulary, so this
    # is unreachable through it — and is therefore written as a non-verdict rather than a guess.
    answer unverified "unexpected-ci-verdict:$ci" "$runs" ;;
esac
