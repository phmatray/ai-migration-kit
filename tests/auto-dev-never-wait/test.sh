#!/usr/bin/env bash
# Golden test for the auto-dev "never wait" invariant (#187).
#
# Two of three phase-1 workers in a live fleet run were killed after doing essentially all of the
# work: each ended its turn to "wait" for a subagent or background suite it had itself dispatched,
# and a one-shot `claude -p` process that ends its turn is dead, not paused. `SKILL.md` already
# documented this hazard at length for phase 2 (waiting on CI), but `commands/auto-dev-worker.md` —
# the literal text a phase-1 worker's context is seeded with — said nothing about it at all.
#
# This suite pins the textual invariant so it cannot regress silently: commands/auto-dev-worker.md
# carries a hard "never wait" rule, naming the forbidden phrasings a worker actually produced.
#
# Reads only files under commands/ — never samples/ — so no kit_guard is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

WORKER_MD="$KIT/commands/auto-dev-worker.md"
[ -f "$WORKER_MD" ] || fail "missing $WORKER_MD"

# 1a. The worker prompt states the one-shot-process warning.
grep -qi "one-shot process" "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md has no 'one-shot process' marker"

# 1b. It names the observed forbidden phrasings verbatim, so a future edit that quietly drops one
#     of the three concrete examples is caught rather than passing on the marker phrase alone.
grep -qF "I'll pause here and wait for" "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md is missing the forbidden phrasing: I'll pause here and wait for..."
grep -qF "I'll pick this back up automatically once it completes" "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md is missing the forbidden phrasing: I'll pick this back up automatically once it completes"
grep -qF "I'll stop issuing further tool calls now and wait" "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md is missing the forbidden phrasing: I'll stop issuing further tool calls now and wait"

echo "PASS: auto-dev-never-wait"
