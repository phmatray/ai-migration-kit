#!/usr/bin/env bash
# RoselineMCP enforcement gate (Claude Code PreToolUse, matcher: Read).
#
# requirements.json makes RoselineMCP `level: required`, but preflight only proves the server is
# CONNECTED. This proves it is USED: a Read of a C# file is denied and the reason names the
# roseline tool that replaces it. Blocking is the point — an advisory reminder loses because the
# Read still returns the file, so the model is already paid by the time the advice lands.
#
# Fails open everywhere (exit 0, no output): no jq, bad payload, no C# solution in sight. The
# plugin installs globally, so a gate that fired in a non-.NET repo would deadlock it.

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
[ "$tool" = "Read" ] || exit 0

fp=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) || exit 0
case "$fp" in *.cs) ;; *) exit 0 ;; esac

# Inert unless this really is a C# solution. `-print -quit` captured into a variable, with the
# `|| true` tests/_lib.sh's any_match() documents: find stops itself on the first hit so nothing
# can SIGPIPE it (#48), and a legitimately-missing path must not abort the gate.
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$(dirname "$fp")
hit=$(find "$cwd" -maxdepth 3 \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) -print -quit 2>/dev/null || true)
[ -n "$hit" ] || exit 0

base=$(basename "$fp")
reason="Blocked by the roseline gate: ${base} is C#, and this kit routes all C# analysis through RoselineMCP. Use these instead of Read:
  - file shape / locate a member  -> mcp__roseline__search_symbols (file: \"${base}\")
  - read one member's body        -> mcp__roseline__get_symbol_info (includeSource: true)
  - usages / implementors / calls -> mcp__roseline__find_references, find_implementations, get_call_graph
  - resolve a file:line           -> mcp__roseline__get_symbol_at_position
  - change code                   -> mcp__roseline__edit_member, rename_symbol
They return only the structure you need and cost far fewer tokens than the whole file."

jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
exit 0
