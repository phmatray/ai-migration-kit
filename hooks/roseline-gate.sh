#!/usr/bin/env bash
# RoselineMCP enforcement gate (Claude Code PreToolUse, matcher: Read).
#
# requirements.json makes RoselineMCP `level: required`, but preflight only proves the server is
# CONNECTED. This proves it is USED: a Read of a C# file is denied and the reason names the
# roseline tool that replaces it. Blocking is the point — an advisory reminder loses because the
# Read still returns the file, so the model is already paid by the time the advice lands.
#
# Every failure path exits 0 with no output, which lets the Read through. That direction is
# deliberate and absolute: the plugin installs globally, so a gate that failed *closed* would
# deadlock repositories it was never meant to touch. Set ROSELINE_GATE=off to disable it outright.

case "${ROSELINE_GATE:-}" in off|0|false|no|disabled) exit 0 ;; esac

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Re-checked even though hooks.json matches "Read": the matcher is a regex, so it also catches
# NotebookRead, which this gate has no business blocking.
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
[ "$tool" = "Read" ] || exit 0

fp=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) || exit 0
case "$fp" in *.cs) ;; *) exit 0 ;; esac

# ---------------------------------------------------------------- is this .cs inside a project?
# Walk UP from the file's own directory. Upward is the direction that answers the question; a
# downward scan from cwd misses the mainstream src/Company.Product/Api/Api.csproj layout entirely
# (depth 4), leaving the gate silently off in exactly the repos it is meant for.
# `-print -quit` captured into a variable with `|| true`, per the lesson tests/_lib.sh's
# any_match() records (#48): find stops itself on the first hit so nothing can SIGPIPE it, and a
# legitimately-missing path must not abort the gate.
hit=""
dir=$(dirname "$fp")
levels=0
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ] && [ "$levels" -lt 40 ]; do
  hit=$(find "$dir" -maxdepth 1 \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) -print -quit 2>/dev/null || true)
  [ -n "$hit" ] && break
  dir=$(dirname "$dir")
  levels=$((levels + 1))
done

# Fallback for a .cs sitting above its project (a loose file at the repo root, say): a shallow
# scan down from the session's cwd.
if [ -z "$hit" ]; then
  cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    hit=$(find "$cwd" -maxdepth 3 \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) -print -quit 2>/dev/null || true)
  fi
fi
[ -n "$hit" ] || exit 0

# ------------------------------------------------------------------------- the one-shot escape
# An identical repeat Read within the window is allowed through — the documented "I genuinely need
# the exact full text" case, and the only way to Edit a C# file (Edit refuses a file the
# conversation has not Read). Both halves of the key are sanitised: a session id or path with a
# slash in it would otherwise build a marker path pointing somewhere else entirely.
sid=$(jq -r '.session_id // "nosession"' <<<"$payload" 2>/dev/null)
sid=$(printf '%s' "${sid:-nosession}" | tr -c 'A-Za-z0-9._-' '_')
key=$(printf '%s' "$fp" | md5 -q 2>/dev/null || printf '%s' "$fp" | md5sum 2>/dev/null | cut -d' ' -f1)
# No hasher at all (minimal containers — the same hosts kit_require_find_quit worries about) would
# leave the key empty, collapsing the marker to one per session: the escape for Foo.cs would then
# let the next .cs file through on its first read. Fall back to the flattened path.
[ -n "$key" ] || key=$(printf '%s' "$fp" | tr -c 'A-Za-z0-9._-' '_' | tail -c 120)
marker="${TMPDIR:-/tmp}/roseline-gate-${sid}-${key}"

# Only a RECENT marker counts. A marker is otherwise cleared solely by the retry that consumes it,
# so the common path — model complies, uses roseline, never retries — leaves one behind forever,
# and a Read of that file hours later (or after --resume, which preserves session_id) would be
# silently allowed. The window keeps "issue the identical Read again" meaning immediately.
if [ -f "$marker" ] && [ -n "$(find "$marker" -mmin -2 2>/dev/null || true)" ]; then
  rm -f "$marker" 2>/dev/null
  exit 0
fi

# If the marker cannot be written the escape can never fire, and denying would deadlock the file
# while the message still tells the reader to retry. Fail open instead.
touch "$marker" 2>/dev/null || exit 0

base=$(basename "$fp")
reason="Blocked by the roseline gate: ${base} is C#, and this kit routes all C# analysis through RoselineMCP. Use these instead of Read:
  - file shape / locate a member  -> mcp__roseline__search_symbols (file: \"${base}\")
  - read one member's body        -> mcp__roseline__get_symbol_info (includeSource: true)
  - usages / implementors / calls -> mcp__roseline__find_references, find_implementations, get_call_graph
  - resolve a file:line           -> mcp__roseline__get_symbol_at_position
  - edit a member body, or rename -> mcp__roseline__edit_member, rename_symbol
They return only the structure you need and cost far fewer tokens than the whole file.
If you need the exact full text -- or you are about to Edit this file, which requires having Read it, or the change is outside a member body (usings, namespace, attributes, top-level statements) -- issue the identical Read again straight away and the retry is allowed through."

jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
exit 0
