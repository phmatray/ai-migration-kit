#!/usr/bin/env bash
# Routing-context hook (Claude Code SessionStart).
#
# The kit's skill-routing table — broken -> debug-issue, a new idea -> create-issue, a planned
# issue -> implement-issue, a ready PR -> merge-pr, the queue -> triage-backlog, etc — lives in
# exactly one place: ${CLAUDE_PLUGIN_ROOT}/AGENTS.md's "## Which kit skill, for what" section
# (#324, #395; moved out of .claude/CLAUDE.md by #525 so every other host reads the same text).
# A plugin install ships those bytes but no host reads a plugin's AGENTS.md on its own (#416) —
# measured: a headless session outside this repo, with the plugin installed, quoted no routing line
# at all.
#
# This hook is how the table travels instead. It fires on SessionStart — start, resume, clear or
# compact, per Claude Code's own event — reads the section straight out of the shipped AGENTS.md and
# prints it as `additionalContext` — never a second copy of the text, which would desynchronise the
# moment either drifts (#324's whole premise). Re-injecting on resume/compact is harmless repetition,
# not a bug: the table is idempotent context, not a one-time side effect.
#
# ADR 0002 (fail open, always) applies verbatim: a third hook takes the same terms and gets no
# second record. There is no deny path here to fail open FROM — every non-print branch below is
# `exit 0` with no output, and the harness reads silence as "nothing to add", not as a block. Set
# ROUTING_CONTEXT=off to disable it outright; unlike the two gates there is no `=on` counterpart —
# there is no launcher probe here for a user to override.

case "${ROUTING_CONTEXT:-}" in off|0|false|no|disabled) exit 0 ;; esac

[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0

agents_md="${CLAUDE_PLUGIN_ROOT}/AGENTS.md"
[ -r "$agents_md" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# Heading to the next `## ` heading, heading line included. awk, not sed, so the "print through but
# not past the next heading" logic reads as one small state machine rather than a sed range (which
# is inclusive of its end pattern and would swallow the following heading too).
section=$(awk '
  /^## Which kit skill, for what/ { flag=1; print; next }
  /^## / { if (flag) exit }
  flag { print }
' "$agents_md")

[ -n "$section" ] || exit 0

jq -n --arg ctx "$section" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null
exit 0
