#!/usr/bin/env bash
# Golden test for the roseline integration — the shipped MCP server config and the PreToolUse gate.
#
# Written fail-path-first (like tests/worktrees-ignored/test.sh): a gate whose PASS path is the
# only one exercised proves nothing. Every case drives the real script over a synthetic hook
# payload, because that payload is the gate's entire input contract.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
n=0

# ------------------------------------------------------------------ 1. the shipped server config
MCP="$KIT/.mcp.json"
[ -f "$MCP" ] || { echo "FAIL: $MCP missing"; exit 1; }
jq -e . "$MCP" >/dev/null 2>&1 || { echo "FAIL: .mcp.json is not valid JSON"; exit 1; }

got=$(jq -r '.mcpServers.roseline | "\(.type)|\(.command)|\(.args | join(","))"' "$MCP")
want='stdio|dnx|RoselineMCP,--yes'
[ "$got" = "$want" ] || { echo "FAIL: .mcp.json roseline entry is '$got', want '$want'"; exit 1; }
echo "ok: .mcp.json ships roseline as $want"

echo "roseline golden test OK"
