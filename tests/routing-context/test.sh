#!/usr/bin/env bash
# Golden test for the routing-context hook — the SessionStart hook that makes the kit's
# skill-routing table (.claude/CLAUDE.md's "## Which kit skill, for what") travel to a session
# where the plugin is installed but the working directory is NOT this repository (#416).
#
# Driven against the REAL, live .claude/CLAUDE.md rather than a fixture copy of the section text —
# on purpose. A copy would desynchronise from #395's table the moment either drifts, exactly the
# second-copy failure #416 exists to prevent, and it could never catch the heading being renamed or
# removed: acceptance criterion 4 requires that THIS suite goes red when that happens, which only
# holds if the "non-empty, names the core skills" assertion below reads the actual file.
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

# Lower bound: the core routing verbs #416's own problem statement names, and every one of them a
# reader outside this repo has to see. Not "every skills/* directory" — the section as it stands
# today names these by skill/command name, not four others (deliver-issue, migrate-legacy,
# review-followups, review-sessions) that postdate #395's table; rewriting the table's CONTENT to
# add them is explicitly out of scope for this issue (Non-goals), so the assertion matches what the
# single-homed section actually says rather than inventing coverage it does not have.
for name in debug-issue create-issue implement-issue merge-pr triage-backlog auto-dev profile-repo setup-repo; do
  case "$ctx" in
    *"$name"*) ;;
    *) echo "FAIL [real]: additionalContext does not name '$name': $ctx"; exit 1 ;;
  esac
done

# Upper bound: catches an extraction that runs away past the next '## ' heading (e.g. a broken
# state machine that never exits) and swallows the rest of the file. The real section is ~730
# bytes; the whole file is ~3.4KB.
len=${#ctx}
[ "$len" -le 2000 ] || { echo "FAIL [real]: additionalContext is $len bytes — extraction likely ran past the section"; exit 1; }

# ---------------------------------------------------------------------------- 2. ROUTING_CONTEXT=off
out=$(run "$KIT" off "$REAL_PATH") || { echo "FAIL [off]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [off]: expected no output with ROUTING_CONTEXT=off, got: $out"; exit 1; }

# ------------------------------------------------------------------- 3. CLAUDE_PLUGIN_ROOT unset
out=$(run "" "" "$REAL_PATH") || { echo "FAIL [unset]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [unset]: expected no output with CLAUDE_PLUGIN_ROOT unset, got: $out"; exit 1; }

# --------------------------------------------------- 4. CLAUDE_PLUGIN_ROOT with no .claude/CLAUDE.md
EMPTY_DIR=$(mktemp -d "$WORK/empty.XXXXXX")
out=$(run "$EMPTY_DIR" "" "$REAL_PATH") || { echo "FAIL [no-claude-md]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [no-claude-md]: expected no output, got: $out"; exit 1; }

# ------------------------------------------------------------------------------- 5. jq absent
# ADR 0002's fail-open contract: no jq, no envelope, still exit 0 — the same non-print path the two
# existing hooks both test for their own required dependency.
NOJQ=$(shim_path "$WORK/nojq")
out=$(run "$KIT" "" "$NOJQ") || { echo "FAIL [no-jq]: hook exited non-zero"; exit 1; }
[ -z "$out" ] || { echo "FAIL [no-jq]: expected no output without jq on PATH, got: $out"; exit 1; }

echo "PASS: routing-context hook — real extraction, off-switch, unset root, no CLAUDE.md, no jq"
