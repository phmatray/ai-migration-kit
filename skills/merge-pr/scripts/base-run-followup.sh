#!/usr/bin/env bash
# base-run-followup.sh — one bounded, non-polling follow-up lookup for a timeout-reasoned
# unverified base verdict (#561).
#
# WHY THIS EXISTS. `base-run-verdict.sh`'s poll loop treats two different situations as
# `timeout`: CI genuinely still pending, and CI clear but the reduced job-name signature hasn't
# repeated across two consecutive polls (the partially-posted-job-graph guard #355 already
# argues for). Under a single worker that converges inside the default 600s budget; under several
# `auto-dev` workers all pushing to the same base and sharing the same CI runners, the job graph
# for one sha can keep shifting long enough that two identical readings never happen inside the
# budget, even though the run is genuinely converging toward green. Measured on this repo,
# 2026-09-12: a 5-worker fleet run answered `unverified (timeout)` for two merges (PR #543/#521,
# PR #549/#520) whose base run had in fact already finished cleanly by the time a human
# re-checked by hand, minutes later, with exactly the lookup this script now makes.
#
# WHAT IT DOES. Exactly ONE `gh run list` lookup for the base branch, resolved BY THE EXACT SHA
# (never by recency — multiple matches resolve to the newest `createdAt`, mirroring
# `base-run-verdict.sh`'s own "reduced, newest wins" rule) — never a second poll loop, never a
# sleep. Maps the result into the SAME report-line grammar (`^(green|RED|unverified) \([a-z-]+\)$`,
# #455) `base-run-verdict.sh` already emits for its own workflow-runs fallback:
#
#   a completed, successful run for the sha           -> green (base-run)
#   a completed, failed run for the sha                -> RED (base-run)
#   no match, or the matched run has no conclusion yet
#     (still queued/in_progress), or the lookup itself
#     fails                                             -> unverified (timeout)
#
# Any other completed conclusion (`cancelled`, `skipped`, `neutral`, `timed_out`,
# `action_required`, `stale`) falls into the last bucket too — this script's whole point is one
# extra free look at a run that was still converging, not a second CI-rule engine; a cancelled or
# otherwise inconclusive run is not evidence the base broke, so it stays a non-verdict rather than
# a fabricated red (the same doctrine `base-run-verdict.sh`'s own cancelled-run handling states).
#
# `merge-pr` Step 5b calls this ONLY when `base-run-verdict.sh --report-line`'s own reason was
# exactly `timeout`; every other verdict/reason is unaffected and this script is never invoked for
# them. It invents no CI rule of its own — decisions/registry.json's `not_decisions` records why,
# the same reasoning as `base-run-verdict.sh`'s own entry.
#
# Usage:
#   base-run-followup.sh [-R <owner/repo>] <base-branch> <sha>
#
# ALWAYS prints exactly one report-line and exits 0 — a non-verdict is a valid answer, not a
# failure, for the same reason `base-run-verdict.sh` documents: a post-merge read must never give
# an autonomous fleet a new way to get stuck on a merge that already landed. The one refusal,
# exit 64, is a usage error before any `gh` call: no base branch, no sha, or an unparseable option.
set -euo pipefail

TOOL="base-run-followup"
usage() { echo "usage: $TOOL.sh [-R <owner/repo>] <base-branch> <sha>" >&2; }
refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

REPO=""
BASE=""
SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -R|--repo) REPO="${2:-}"; [ -n "$REPO" ] || refuse "-R needs an <owner/repo>"; shift 2 ;;
    --)        shift ;;
    -*)        refuse "unexpected option: $1" ;;
    *)
      if   [ -z "$BASE" ]; then BASE="$1"
      elif [ -z "$SHA" ];  then SHA="$1"
      else refuse "unexpected extra argument: $1 (usage: <base-branch> <sha>)"
      fi
      shift ;;
  esac
done

[ -n "$BASE" ] || refuse "no base branch given"
[ -n "$SHA" ]  || refuse "no sha given"
case "$SHA" in
  *[!0-9a-fA-F]*) refuse "'$SHA' is not a hex sha" ;;
esac

command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"
command -v gh > /dev/null 2>&1 || refuse "gh is missing — there is no other way to read run list"

answer() { printf '%s\n' "$1"; exit 0; }

GH_ARGS=(run list --branch "$BASE" --json headSha,conclusion,workflowName,createdAt --limit 100)
[ -n "$REPO" ] && GH_ARGS=(-R "$REPO" "${GH_ARGS[@]}")

# A failed or empty lookup is not evidence about the base — it is the same "nothing to act on"
# non-verdict as no match at all. `set +e` around it: this is a deliberate single try, not a poll
# loop, so nothing here should ever kill the script under `set -e`.
raw=""
rc=0
set +e
raw=$(gh "${GH_ARGS[@]}" 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] && [ -n "$raw" ] || answer "unverified (timeout)"

# The newest match for this exact sha — never the newest ON THE BRANCH (that would be the
# recency trap `base-run-verdict.sh`'s own suite pins red; a sibling merge's run could otherwise
# donate its verdict here). An unparseable response is the same non-verdict as no response.
match=$(printf '%s' "$raw" | jq -c --arg sha "$SHA" \
  '[ .[]? | select(.headSha == $sha) ] | sort_by(.createdAt) | last // empty' 2>/dev/null) || match=""
[ -n "$match" ] || answer "unverified (timeout)"

conclusion=$(printf '%s' "$match" | jq -r '.conclusion // ""' 2>/dev/null || echo "")
case "$conclusion" in
  success) answer "green (base-run)" ;;
  failure) answer "RED (base-run)" ;;
  *)       answer "unverified (timeout)" ;;   # no conclusion yet (still running), or an
                                               # inconclusive one (cancelled/skipped/…) — neither
                                               # is evidence the base broke
esac
