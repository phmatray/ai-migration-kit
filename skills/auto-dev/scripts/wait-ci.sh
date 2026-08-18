#!/usr/bin/env bash
# auto-dev wait-ci — block until each PR's gating check is FINAL, then print the result table.
#
# Why this exists (see SKILL.md, "NEVER dispatch phase 2 while CI is pending"):
# a phase-2 merge worker is a one-shot `claude -p` session. Dispatched while CI is still
# pending, it reaches for a background watch ("I'll resume when the poll notifies me"),
# ends its turn, and the process dies mid-merge — the PR just stays open. That is a
# dispatch-timing bug, not a prompt-wording one: dispatching at "PR ready" *guarantees*
# the worker meets a pending run. Five worker sessions were lost this way in a single
# .NET run with Testcontainers (Build & Test there takes 16-20 min: it pulls ~4.4 GB of
# SQL Server + Oracle images) before the wait was moved up to the supervisor.
#
# So: the SUPERVISOR runs this in the background, and only once it returns does it
# dispatch phase 2 — with the finished check table pasted into the prompt, so the worker
# has nothing left to wait for. Measured: ~11 min of idle-and-die -> 17-55 s clean merges.
#
# Usage:
#   scripts/wait-ci.sh <pr> [pr...]              # default gating check: "Build & Test"
#   CHECK="CI / build" scripts/wait-ci.sh 42     # override for another repo's check name
#
# Exit 0 when every PR's gating check has left `pending`; 1 on timeout.
#
# ⚠️ PARSING GOTCHA — do not "simplify" the awk below.
# `gh pr checks` emits TAB-separated columns and check names contain spaces
# ("Build & Test"). With awk's default whitespace splitting, $2 is "&" — not the status —
# so the waiter sees a non-`pending` value and exits instantly claiming success. That
# false green sends you straight back into the failure this script exists to prevent.
# Splitting on tabs (-F'\t') is load-bearing.

set -uo pipefail

CHECK="${CHECK:-Build & Test}"
POLL_SECONDS="${POLL_SECONDS:-60}"
MAX_POLLS="${MAX_POLLS:-60}"   # 60 x 60s = up to 60 min

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <pr> [pr...]   (env: CHECK, POLL_SECONDS, MAX_POLLS)" >&2
  exit 2
fi

PRS=("$@")

for i in $(seq 1 "$MAX_POLLS"); do
  all_final=1
  line=""
  for pr in "${PRS[@]}"; do
    state=$(gh pr checks "$pr" 2>/dev/null \
      | grep -F "$CHECK" \
      | head -1 \
      | awk -F'\t' '{print $2}')          # <- tabs, NOT default whitespace. See above.
    [ -z "$state" ] && state="unknown"
    line="${line} PR${pr}=${state}"
    case "$state" in
      pending|unknown) all_final=0 ;;
    esac
  done

  echo "[$(date -u +%T)Z] poll ${i}:${line}"

  if [ "$all_final" -eq 1 ]; then
    echo "=== ALL '${CHECK}' CHECKS FINAL ==="
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
