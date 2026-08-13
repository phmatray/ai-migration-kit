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

# The gate's one-shot escape keys off marker files under $TMPDIR. Point TMPDIR at the scratch so
# every run starts with none: with the real TMPDIR they survive between runs, and the *second* run
# of this suite would find Foo.cs already marked and watch "first read is denied" pass instead —
# a suite that goes green off a stale file from the run before. Scratch is wiped by kit_cleanup.
export TMPDIR="$WORK"

# ------------------------------------------------------------------ 1. the shipped server config
MCP="$KIT/.mcp.json"
[ -f "$MCP" ] || { echo "FAIL: $MCP missing"; exit 1; }
jq -e . "$MCP" >/dev/null 2>&1 || { echo "FAIL: .mcp.json is not valid JSON"; exit 1; }

got=$(jq -r '.mcpServers.roseline | "\(.type)|\(.command)|\(.args | join(","))"' "$MCP")
want='stdio|dnx|RoselineMCP,--yes'
[ "$got" = "$want" ] || { echo "FAIL: .mcp.json roseline entry is '$got', want '$want'"; exit 1; }
echo "ok: .mcp.json ships roseline as $want"

# ------------------------------------------------------------------------------- 2. the gate
GATE="$KIT/hooks/roseline-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# find -print -quit is load-bearing in the gate's C# detection; #48 is why this is asserted.
kit_require_find_quit

# A scratch repo that looks like a C# solution ($1=marker filename), or one that does not.
csharp_repo() { n=$((n + 1)); local d="$WORK/cs$n"; mkdir -p "$d"; : > "$d/${1:-App.csproj}"; printf '%s' "$d"; }
plain_repo()  { n=$((n + 1)); local d="$WORK/plain$n"; mkdir -p "$d"; : > "$d/README.md"; printf '%s' "$d"; }

# Drives the gate with a synthetic payload. Asserts the decision and, when denying, the reason.
# $1 name  $2 expected decision ("deny" or "pass")  $3 substring the reason must contain  $4 payload
verdict() {
  local name="$1" want="$2" want_msg="$3" payload="$4" out decision
  out=$(printf '%s' "$payload" | bash "$GATE" 2>/dev/null || true)
  if [ -z "$out" ]; then decision="pass"; else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed)
  fi
  if [ "$decision" != "$want" ]; then
    echo "FAIL [$name]: expected $want, got $decision"; echo "$out"; exit 1
  fi
  if [ -n "$want_msg" ]; then
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' \
      | grep -qF "$want_msg" || { echo "FAIL [$name]: reason lacks '$want_msg'"; echo "$out"; exit 1; }
  fi
  echo "ok: $name -> $decision"
}

pay() { # $1 tool  $2 file_path  $3 cwd  $4 session
  jq -nc --arg t "$1" --arg f "$2" --arg c "$3" --arg s "$4" \
    '{session_id:$s, cwd:$c, tool_name:$t, tool_input:{file_path:$f}}'
}

CS=$(csharp_repo); PL=$(plain_repo)

verdict "first .cs read in a C# repo"  deny "search_symbols" "$(pay Read "$CS/Foo.cs"    "$CS" s1)"
verdict "csproj is not C# source"      pass ""               "$(pay Read "$CS/A.csproj"  "$CS" s1)"
verdict "razor markup"                 pass ""               "$(pay Read "$CS/X.razor"   "$CS" s1)"
verdict "markdown"                     pass ""               "$(pay Read "$CS/README.md" "$CS" s1)"
verdict "no C# solution discoverable"  pass ""               "$(pay Read "$PL/Foo.cs"    "$PL" s1)"
verdict "a tool other than Read"       pass ""               "$(pay Grep "$CS/Foo.cs"    "$CS" s1)"
verdict "malformed payload fails open" pass ""               'not json at all'

# ------------------------------------------------------- 3. the one-shot "I really need it" escape
ESC=$(csharp_repo)
P=$(pay Read "$ESC/Bar.cs" "$ESC" escape-session)
verdict "first read is denied"          deny "search_symbols" "$P"
verdict "identical retry passes"        pass ""               "$P"
verdict "third read denies again"       deny "search_symbols" "$P"

# The escape is per-file, not per-session: a different file is still denied after one was let through.
Q=$(pay Read "$ESC/Baz.cs" "$ESC" escape-session)
verdict "a different file is denied"    deny "search_symbols" "$Q"

# ...and per-session, not global: the same file under another session id is denied on ITS first read,
# even though the marker for the first session was just consumed.
S=$(pay Read "$ESC/Bar.cs" "$ESC" other-session)
verdict "another session is denied"     deny "search_symbols" "$S"

# --------------------------------------------------------------------- 4. the hook registration
HJ="$KIT/hooks/hooks.json"
[ -f "$HJ" ] || { echo "FAIL: $HJ missing"; exit 1; }
jq -e . "$HJ" >/dev/null 2>&1 || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }

got=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Read") | .hooks[0].command' "$HJ")
case "$got" in
  *'${CLAUDE_PLUGIN_ROOT}'*roseline-gate.sh) echo "ok: hooks.json wires Read -> $got" ;;
  *) echo "FAIL: Read matcher command is '$got'; must reference \${CLAUDE_PLUGIN_ROOT}/hooks/roseline-gate.sh"; exit 1 ;;
esac

# The path in hooks.json must name a file that actually ships — a typo here is a hook that never
# fires, and a hook that never fires looks exactly like a hook that found nothing to block.
resolved="${got/\$\{CLAUDE_PLUGIN_ROOT\}/$KIT}"
[ -x "$resolved" ] || { echo "FAIL: hooks.json points at '$resolved', which is not an executable file"; exit 1; }
echo "ok: the registered command resolves to a shipped executable"

echo "roseline golden test OK"
