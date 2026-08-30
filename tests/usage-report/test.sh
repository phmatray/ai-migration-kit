#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/usage_report.py's transcript discovery (#281).
#
# The bug: the script discovered sessions with one glob, `<proj>/*.jsonl`, which matches only the
# transcripts sitting DIRECTLY in the project directory. A worker dispatched via the Agent tool
# writes its transcript to `<proj>/<session-id>/subagents/agent-*.jsonl` instead — a layout the
# glob never opens, and nothing in the output said so. Measured on this repo's own 2026-08-27
# fleet run: 21 sub-agent transcripts carrying 86% of the run's tokens were silently invisible,
# and the ORCHESTRATOR vs WORKERS split was wrong in exactly the direction that flatters the
# orchestrator's share.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

SCRIPT="$KIT/skills/auto-dev/scripts/usage_report.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

# ------------------------------------------------------------------------------- fixture builders
#
# Each transcript line only needs a `message.model` + `message.usage` object — scan() in
# usage_report.py reads nothing else.
write_usage_line() {
  # $1 = out file (appended), $2 = model, $3..$6 = input/output/cacheWrite/cacheRead
  local out="$1" model="$2" tin="$3" tout="$4" tcw="$5" tcr="$6"
  python3 - "$out" "$model" "$tin" "$tout" "$tcw" "$tcr" <<'PY'
import json, sys
out, model, tin, tout, tcw, tcr = sys.argv[1:7]
rec = {
    "type": "assistant",
    "message": {
        "model": model,
        "usage": {
            "input_tokens": int(tin),
            "output_tokens": int(tout),
            "cache_creation_input_tokens": int(tcw),
            "cache_read_input_tokens": int(tcr),
        },
    },
}
with open(out, "a") as f:
    f.write(json.dumps(rec) + "\n")
PY
}

MODEL="claude-sonnet-4-5-20250929"

# ------------------------------------------------------------------------- two-kind (the bug)
#
# top session "sess-main": input 1500 | output 300 | cacheWrite 50  | cacheRead 15 → 1,865 tok
# sub session "agent-a1" (parent sess-main): input 2000 | output 400 | cacheWrite 100 | cacheRead 20 → 2,520 tok
# grand total: 4,385 tok, across 2 sessions (1 top-level, 1 sub-agent).
PROJ1=$(kit_scratch)
write_usage_line "$PROJ1/sess-main.jsonl" "$MODEL" 1000 200 50 10
write_usage_line "$PROJ1/sess-main.jsonl" "$MODEL" 500  100 0  5

mkdir -p "$PROJ1/sess-main/subagents"
write_usage_line "$PROJ1/sess-main/subagents/agent-a1.jsonl" "$MODEL" 2000 400 100 20

OUT1=$(kit_scratch)/out.txt
python3 "$SCRIPT" "$PROJ1" --main sess-main > "$OUT1" 2>&1 || {
  echo "FAIL: usage_report.py exited non-zero on the two-kind fixture"; cat "$OUT1"; exit 1; }

# The grand total is the SUM of both files, not the top-level file alone (the original bug).
grep -q "total tokens 4,385" "$OUT1" || {
  echo "FAIL: grand total is not the sum of the top-level AND sub-agent transcripts (expected 4,385)"
  cat "$OUT1"; exit 1; }

# Session count is 2 (both files counted).
grep -q "SESSIONS: 2 in $PROJ1" "$OUT1" || {
  echo "FAIL: header does not report 2 sessions"; cat "$OUT1"; exit 1; }

echo "ok: two-kind — a top-level AND an Agent-tool sub-agent transcript are both discovered and summed"
