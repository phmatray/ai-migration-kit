#!/usr/bin/env bash
# auto-dev wait-ci — block until each PR's gating checks are ALL final, then print the result table.
#
# Why this exists (see SKILL.md, "NEVER dispatch phase 2 while CI is pending"):
# a phase-2 merge worker is a background sub-agent whose final message is its report, and
# whose run ends with its turn (#314; before 2.0 it was a one-shot process, and the rule
# predates the substrate). Dispatched while CI is still pending, the only thing it can do
# is wait — so it reaches for a background watch ("I'll resume when the poll notifies me"),
# ends its turn, and its run is over mid-merge: what the supervisor receives is that
# deferral as the report, nothing resumes the agent, and the PR just stays open. That is
# a dispatch-timing bug, not a prompt-wording one: dispatching at "PR ready" *guarantees*
# the worker meets a pending run. Five worker sessions were lost this way in a single
# .NET run with Testcontainers (Build & Test there takes 16-20 min: it pulls ~4.4 GB of
# SQL Server + Oracle images) before the wait was moved up to the supervisor.
#
# So: the SUPERVISOR runs this in the background, and only once it returns does it
# dispatch phase 2 — with the finished check table pasted into the prompt, so the worker
# has nothing left to wait for. Measured: ~11 min of idle-and-die -> 17-55 s clean merges.
#
# WHAT COUNTS AS "DONE" (#188). This used to model a repo as having exactly ONE gating check,
# picked by a hardcoded default name (`CHECK="Build & Test"`) and matched with `grep -F "$CHECK"`
# against `gh pr checks`'s plain-text table. That is wrong for a repo with more than one
# independently-gating check (this kit's own `kit` + `title-gate`, added by #57): no single name
# can be both, so setting CHECK to either one false-greens past the other, and leaving CHECK at
# the default matches nothing at all on such a repo — `state` came back empty, was folded into
# "unknown", and "unknown" polled to MAX_POLLS and exited 1 after up to an hour without ever
# returning a verdict. A guard that stalls or half-fires is worse than one that is obviously
# absent, because it looks like protection.
#
# So this waits on EVERY check `gh pr checks <pr> --json name,state,bucket` reports, with no
# per-repo CHECK override required for correctness. `bucket` is gh's OWN classification of a
# check's state into `pass`/`fail`/`pending`/`skipping`/`cancel` (pinned against `gh pr checks
# --help` and a real PR — see tests/wait-ci/test.sh's header): a check is final once its bucket
# leaves `pending`, matching this script's pre-existing all_final semantics one level down.
# Reading `bucket` rather than re-deriving it from raw `state` strings (QUEUED, IN_PROGRESS,
# STALE, ACTION_REQUIRED, whatever gh adds next) means this script never has to track gh's own
# state vocabulary — that classification is exactly what the field exists for.
#
# Why `--json` + jq rather than the old plain-table parse: that table is TAB-separated and check
# names can contain spaces ("Build & Test"), a column-alignment ambiguity a careless edit could
# get wrong again. `--json name,state,bucket` names each field, so there is nothing left to
# misalign no matter how a check is named. `jq` is a `required` prerequisite (requirements.json).
#
# Usage:
#   scripts/wait-ci.sh <pr> [pr...]                # waits on every check GitHub reports
#   CHECK="kit,title-gate" scripts/wait-ci.sh 42    # optional allow-list: ignore any check whose
#                                                    # name is not in this comma-separated list —
#                                                    # for a repo that deliberately wants to skip
#                                                    # one known non-gating check, not the default
#
# Exit 0 once every (filtered) check has left the `pending` bucket for every PR; 2 immediately if
# a PR reports zero checks for MAX_ZERO_POLLS consecutive polls (nothing to wait on — most likely
# no CI configured on this branch, not worth a silent hour-long stall); 1 on timeout (MAX_POLLS
# reached with at least one check still pending).
#
# GENUINE zero checks vs a TRANSIENT `gh` failure (rate limit, network blip, an auth hiccup) look
# identical on stdout alone — both leave it empty — so counting either one toward MAX_ZERO_POLLS
# would let a couple of unlucky API calls produce the same wrong "no CI configured" verdict this
# script exists to avoid, after as little as ~2 polls instead of a real MAX_POLLS timeout. gh's own
# source (cli/cli pkg/cmd/pr/checks: `populateStatusChecks`) only ever fails a `--json` call BEFORE
# printing anything for exactly one reason — zero checks exist — and always with the same message,
# "no checks reported on the '<branch>' branch" (measured on PR #291 of this repo, a
# release-please branch with no CI wired: exit 1, that text on stderr, nothing on stdout, WITH
# --json). So gh failing with that exact wording is treated as a genuine zero-checks poll (counts
# toward MAX_ZERO_POLLS); gh failing any other way is treated as transient — logged, not counted
# either way, and the poll just continues — matching the old script's fallback of folding any
# failure into "unknown" and polling on rather than giving up early with a wrong verdict.

set -uo pipefail

command -v jq > /dev/null 2>&1 || {
  echo "wait-ci: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

CHECK="${CHECK:-}"                     # optional comma-separated allow-list; empty = every check
POLL_SECONDS="${POLL_SECONDS:-60}"
MAX_POLLS="${MAX_POLLS:-60}"           # 60 x 60s = up to 60 min
MAX_ZERO_POLLS="${MAX_ZERO_POLLS:-2}"  # consecutive zero-check polls before failing fast (exit 2)

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <pr> [pr...]   (env: CHECK, POLL_SECONDS, MAX_POLLS, MAX_ZERO_POLLS)" >&2
  exit 2
fi

PRS=("$@")
ZERO_POLLS=()
for _pr in "${PRS[@]}"; do ZERO_POLLS+=(0); done

# Captures each `gh pr checks --json` call's stderr so a genuine "no checks reported" can be told
# apart from any other failure (see the header). Guarded the way survey.sh/guarded-push.sh capture
# stderr elsewhere in this kit: a failing mktemp must not be misread as "gh printed nothing".
GH_ERR_FILE=""
if GH_ERR_FILE="$(mktemp 2>/dev/null)"; then
  trap 'rm -f "$GH_ERR_FILE"' EXIT
fi

# One jq call per PR per poll: applies the optional CHECK allow-list, then reduces the (possibly
# filtered) checks array to three tab-separated fields — how many checks, how many of those are
# still pending, and a "name:state,..." line for the human-readable poll log.
JQ_SUMMARY='
  ( ($allow | if . == "" then [] else (split(",") | map(gsub("^[ \t]+|[ \t]+$";""))) end) ) as $names
  | (if ($names | length) > 0 then map(select(.name as $n | $names | index($n) != null)) else . end) as $f
  | { count: ($f | length),
      pending: ([$f[] | select(.bucket == "pending")] | length),
      line: ([$f[] | "\(.name):\(.state)"] | join(",")) }
  | "\(.count)\t\(.pending)\t\(.line)"
'

for i in $(seq 1 "$MAX_POLLS"); do
  all_final=1
  line=""
  idx=0
  for pr in "${PRS[@]}"; do
    if json=$(gh pr checks "$pr" --json name,state,bucket 2>"${GH_ERR_FILE:-/dev/null}"); then
      gh_rc=0
    else
      gh_rc=$?
    fi
    gh_err=''
    [ -n "$GH_ERR_FILE" ] && gh_err=$(cat -- "$GH_ERR_FILE" 2>/dev/null)

    transient=0
    if [ "$gh_rc" -ne 0 ]; then
      if printf '%s' "$gh_err" | grep -qi 'no checks reported'; then
        json='[]'   # genuine zero checks — see the header
      else
        transient=1
      fi
    fi
    [ -n "$json" ] || json='[]'

    if [ "$transient" -eq 1 ]; then
      # Neither confirms nor disconfirms "zero checks": ZERO_POLLS is left exactly as it was, so a
      # blip can't manufacture progress toward MAX_ZERO_POLLS, and can't erase real progress either.
      line="${line} PR${pr}=[gh error, retrying: ${gh_err:-<no output>}]"
      all_final=0
      idx=$((idx + 1))
      continue
    fi

    summary=$(printf '%s' "$json" | jq -r --arg allow "$CHECK" "$JQ_SUMMARY" 2>/dev/null) \
      || summary=$'0\t0\t'
    count=0; pending=0; checkline=''
    IFS=$'\t' read -r count pending checkline <<< "$summary"

    if [ "${count:-0}" -eq 0 ]; then
      ZERO_POLLS[$idx]=$(( ZERO_POLLS[idx] + 1 ))
      line="${line} PR${pr}=[no checks found]"
      all_final=0
    else
      ZERO_POLLS[$idx]=0
      line="${line} PR${pr}=[${checkline}]"
      [ "${pending:-0}" -eq 0 ] || all_final=0
    fi
    idx=$((idx + 1))
  done

  echo "[$(date -u +%T)Z] poll ${i}:${line}"

  idx=0
  for pr in "${PRS[@]}"; do
    if [ "${ZERO_POLLS[$idx]}" -ge "$MAX_ZERO_POLLS" ]; then
      echo "wait-ci: no checks found for PR ${pr} after ${MAX_ZERO_POLLS} poll(s) — verify CI is configured on this PR/branch" >&2
      exit 2
    fi
    idx=$((idx + 1))
  done

  if [ "$all_final" -eq 1 ]; then
    if [ -n "$CHECK" ]; then
      echo "=== ALL CHECKS IN ALLOW-LIST FINAL (CHECK=${CHECK}) ==="
    else
      echo "=== ALL GATING CHECKS FINAL ==="
    fi
    for pr in "${PRS[@]}"; do
      echo "--- PR ${pr} ---"
      gh pr checks "$pr" 2>&1 | head -10
      gh pr view "$pr" --json number,state,isDraft,mergeStateStatus \
        --jq '"  state=\(.state) draft=\(.isDraft) mergeState=\(.mergeStateStatus)"' 2>/dev/null
    done
    exit 0
  fi

  sleep "$POLL_SECONDS"
done

echo "=== TIMEOUT after ${MAX_POLLS} polls (~$((MAX_POLLS * POLL_SECONDS / 60)) min) ==="
exit 1
