#!/usr/bin/env bash
# Golden test for the routing-context hook — the SessionStart hook that makes the kit's
# skill-routing table (AGENTS.md's "## Which kit skill, for what") travel to a session where the
# plugin is installed but the working directory is NOT this repository (#416).
#
# Driven against the REAL, live AGENTS.md rather than a fixture copy of the section text — on
# purpose. A copy would desynchronise from the table the moment either drifts, exactly the
# second-copy failure #416 exists to prevent, and it could never catch the heading being renamed or
# removed: acceptance criterion 4 requires that THIS suite goes red when that happens, which only
# holds if the "non-empty, names the core skills" assertion below reads the actual file.
#
# The table's home moved from .claude/CLAUDE.md to AGENTS.md (#525) so hosts other than Claude Code
# can read it too. Cases 6 and 7 pin that move: CLAUDE.md keeps no second copy, and the hook reads
# AGENTS.md — a root holding the section only in .claude/CLAUDE.md gets nothing.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
kit_guard kit_guard_samples_unchanged

HOOK="$KIT/hooks/routing-context.sh"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK missing or not executable"; exit 1; }

# A PATH holding exactly what the hook shells out to, plus whichever stubs are named — built by
# NAMING the tools rather than by subtracting one from $PATH, the same shape tests/git-gate/test.sh
# uses for its own shim, so the "jq absent" case holds on every host regardless of what else is
# installed there. Only `bash` (to invoke the hook) and `awk` (its extraction) are symlinked real —
# the hook shells out to nothing else.
shim_path() { # $1 destination dir; $2… stub names (empty, always-exit-0 executables)
  local d="$1" c p; shift
  mkdir -p "$d"
  for c in bash awk; do
    p=$(command -v "$c" 2>/dev/null) || continue
    ln -s "$p" "$d/$c" 2>/dev/null || true
  done
  for c in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"; done
  printf '%s' "$d"
}

run() { # $1 CLAUDE_PLUGIN_ROOT (or "" for unset)  $2 ROUTING_CONTEXT (or "")  $3 PATH
  local root="$1" rc="$2" path="$3" rc_out=0
  if [ -n "$root" ]; then
    out=$(env PATH="$path" CLAUDE_PLUGIN_ROOT="$root" ROUTING_CONTEXT="$rc" bash "$HOOK" 2>/dev/null) || rc_out=$?
  else
    out=$(env -u CLAUDE_PLUGIN_ROOT PATH="$path" ROUTING_CONTEXT="$rc" bash "$HOOK" 2>/dev/null) || rc_out=$?
  fi
  printf '%s' "$out"
  return "$rc_out"
}

REAL_PATH="$PATH"

# ---------------------------------------------------------------------- 1. the real extraction
out=$(run "$KIT" "" "$REAL_PATH") || { echo "FAIL [real]: hook exited non-zero; its contract is always exit 0"; exit 1; }
[ -n "$out" ] || { echo "FAIL [real]: expected a non-empty additionalContext block, got nothing"; exit 1; }

echo "$out" | jq -e . >/dev/null 2>&1 || { echo "FAIL [real]: stdout is not valid JSON: $out"; exit 1; }
event=$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName // empty')
[ "$event" = "SessionStart" ] || { echo "FAIL [real]: hookEventName is '$event', want SessionStart"; exit 1; }
ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
[ -n "$ctx" ] || { echo "FAIL [real]: additionalContext is empty"; exit 1; }
case "$ctx" in
  "## Which kit skill, for what"*) ;;
  *) echo "FAIL [real]: additionalContext does not begin with the section heading: $ctx"; exit 1 ;;
esac

# Lower bound: the core routing verbs #416's own problem statement names, and every one of them a
# reader outside this repo has to see. Not "every skills/* directory" — the section names these by
# skill/command name, not four others (deliver-issue, migrate-legacy, review-followups,
# review-sessions) that postdate #395's table; rewriting the table's CONTENT to add them is out of
# scope for #416 and for #525, which moves the section without changing what it routes.
for name in debug-issue create-issue implement-issue merge-pr triage-backlog auto-dev profile-repo setup-repo; do
  case "$ctx" in
    *"$name"*) ;;
    *) echo "FAIL [real]: additionalContext does not name '$name': $ctx"; exit 1 ;;
  esac
done

# Upper bound: catches an extraction that runs away past the next '## ' heading (e.g. a broken
# state machine that never exits) and swallows the rest of the file. The real section is under a
# kilobyte; the whole of AGENTS.md is several.
len=${#ctx}
[ "$len" -le 2000 ] || { echo "FAIL [real]: additionalContext is $len bytes — extraction likely ran past the section"; exit 1; }

# ---------------------------------------------------------------------------- 2. ROUTING_CONTEXT=off
out=$(run "$KIT" off "$REAL_PATH") || { echo "FAIL [off]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [off]: expected no output with ROUTING_CONTEXT=off, got: $out"; exit 1; }

# ------------------------------------------------------------------- 3. CLAUDE_PLUGIN_ROOT unset
out=$(run "" "" "$REAL_PATH") || { echo "FAIL [unset]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [unset]: expected no output with CLAUDE_PLUGIN_ROOT unset, got: $out"; exit 1; }

# ---------------------------------------------------------- 4. CLAUDE_PLUGIN_ROOT with no AGENTS.md
EMPTY_DIR=$(mktemp -d "$WORK/empty.XXXXXX")
out=$(run "$EMPTY_DIR" "" "$REAL_PATH") || { echo "FAIL [no-agents-md]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [no-agents-md]: expected no output, got: $out"; exit 1; }

# ------------------------------------------------------------------------------- 5. jq absent
# ADR 0002's fail-open contract: no jq, no envelope, still exit 0 — the same non-print path the two
# existing hooks both test for their own required dependency.
NOJQ=$(shim_path "$WORK/nojq")
out=$(run "$KIT" "" "$NOJQ") || { echo "FAIL [no-jq]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [no-jq]: expected no output without jq on PATH, got: $out"; exit 1; }

# ---------------------------------------------------- 6. .claude/CLAUDE.md keeps no second copy
if grep -q '^## Which kit skill, for what' "$KIT/.claude/CLAUDE.md"; then
  echo "FAIL [one-home]: .claude/CLAUDE.md still carries the '## Which kit skill, for what' section — AGENTS.md is its home"
  exit 1
fi

# --------------------------------------------------------- 7. the hook reads AGENTS.md, not CLAUDE.md
OLD_HOME=$(mktemp -d "$WORK/old-home.XXXXXX")
mkdir -p "$OLD_HOME/.claude"
printf '## Which kit skill, for what\n\nbroken -> debug-issue\n' > "$OLD_HOME/.claude/CLAUDE.md"
out=$(run "$OLD_HOME" "" "$REAL_PATH") || { echo "FAIL [source]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [source]: the hook still reads .claude/CLAUDE.md: $out"; exit 1; }
printf '## Which kit skill, for what\n\nbroken -> debug-issue\n' > "$OLD_HOME/AGENTS.md"
out=$(run "$OLD_HOME" "" "$REAL_PATH") || { echo "FAIL [source]: hook exited non-zero"; exit 1; }
case "$out" in
  *debug-issue*) ;;
  *) echo "FAIL [source]: a root with the section in AGENTS.md produced no context: $out"; exit 1 ;;
esac

echo "PASS: routing-context hook — real extraction from AGENTS.md, off-switch, unset root, no AGENTS.md, no jq, one home, source file"
