#!/usr/bin/env bash
# Routing-context hook (Claude Code SessionStart).
#
# The kit's skill-routing table — broken -> debug-issue, a new idea -> create-issue, a planned
# issue -> implement-issue, a ready PR -> merge-pr, the queue -> triage-backlog, etc — lives in
# exactly one place: ${CLAUDE_PLUGIN_ROOT}/.claude/CLAUDE.md's "## Which kit skill, for what"
# section (#324, #395). That file is a project instruction file: Claude Code loads it only when the
# working directory IS this repository. A plugin install elsewhere ships the bytes but never reads
# them (#416) — measured: a headless session outside this repo, with the plugin installed, quotes
# no routing line at all.
#
# This hook is how the table travels instead. It fires once per session (SessionStart), reads the
# section straight out of the shipped CLAUDE.md and prints it as `additionalContext` — never a
# second copy of the text, which would desynchronise the moment either drifts (#324's whole premise).
#
# ADR 0002 (fail open, always) applies verbatim: a third hook takes the same terms and gets no
# second record. There is no deny path here to fail open FROM — every non-print branch below is
# `exit 0` with no output, and the harness reads silence as "nothing to add", not as a block. Set
# ROUTING_CONTEXT=off to disable it outright; unlike the two gates there is no `=on` counterpart —
# there is no launcher probe here for a user to override.

case "${ROUTING_CONTEXT:-}" in off|0|false|no|disabled) exit 0 ;; esac

[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0

claude_md="${CLAUDE_PLUGIN_ROOT}/.claude/CLAUDE.md"
[ -r "$claude_md" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# Heading to the next `## ` heading, heading line included. awk, not sed, so the "print through but
# not past the next heading" logic reads as one small state machine rather than a sed range (which
# is inclusive of its end pattern and would swallow the following heading too).
section=$(awk '
  /^## Which kit skill, for what/ { flag=1; print; next }
  /^## / { if (flag) exit }
  flag { print }
' "$claude_md")

[ -n "$section" ] || exit 0

jq -n --arg ctx "$section" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null
exit 0
