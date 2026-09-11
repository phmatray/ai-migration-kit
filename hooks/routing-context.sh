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
# This hook is how the table travels instead. It fires on SessionStart — start, resume, clear or
# compact, per Claude Code's own event — reads the section straight out of the shipped CLAUDE.md and
# prints it as `additionalContext` — never a second copy of the text, which would desynchronise the
# moment either drifts (#324's whole premise). Re-injecting on resume/compact is harmless repetition,
# not a bug: the table is idempotent context, not a one-time side effect.
#
# ADR 0002 (fail open, always) applies verbatim: a third hook takes the same terms and gets no
# second record. There is no deny path here to fail open FROM — every non-print branch below is
# `exit 0` with no output, and the harness reads silence as "nothing to add", not as a block. Set
# ROUTING_CONTEXT=off to disable it outright; unlike the two gates there is no `=on` counterpart —
# there is no launcher probe here for a user to override.
#
# After the table it prints two lines of its own (#512): `Kit root: <CLAUDE_PLUGIN_ROOT>` and the
# guards' absolute paths. The table says WHICH skill; nothing said WHERE the kit lives, so sessions
# spelled the guards cwd-relative and five guesses at the kit's path failed in four sessions. This is
# an EXTRA layer, not the mechanism: whether SessionStart context reaches a sub-agent dispatched with
# `Agent(...)` is unverified, so the write-gate's deny text — which names every guard by absolute
# path (`guard_hint` in hooks/git-write-gate.sh) and has been quoted back by a worker — is what the
# fix rests on. These lines are derived from the same root, never a second copy of the table.

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

# Where the kit lives, and each guard by its full absolute path — only the ones that exist there,
# the rule guard_hint keeps in the write-gate (#512 — see the header).
root="${CLAUDE_PLUGIN_ROOT%/}"
guards=""
for g in skills/implement-issue/scripts/guarded-commit.sh skills/implement-issue/scripts/guarded-push.sh \
         skills/implement-issue/scripts/guarded-merge.sh skills/merge-pr/scripts/guarded-pr-merge.sh; do
  if [ -f "$root/$g" ]; then
    if [ -n "$guards" ]; then guards="$guards · $root/$g"; else guards="$root/$g"; fi
  fi
done
section="$section

Kit root: $root"
if [ -n "$guards" ]; then
  section="$section
Guards (invoke by absolute path from any repository, and pass these paths into any sub-agent you dispatch): $guards"
fi

jq -n --arg ctx "$section" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null
exit 0
