#!/usr/bin/env bash
# Human-in-the-loop reproduction loop — the last rung of feedback-loop.md's ladder.
#
# Ported from mattpocock/skills (MIT), engineering/diagnosing-bugs.
#
# WHY THIS EXISTS. Some bugs only appear when a human clicks: an SSO flow, a hardware dialog, a
# device you cannot automate. The temptation there is to give up on a feedback loop and start
# hypothesising from the code — the exact failure `systematic-debugging` prevents. So don't drop the
# loop; drive the human with it. The script asks for one action at a time, captures what they saw,
# and prints the answers as KEY=VALUE lines the agent parses — a slow, structured loop instead of a
# fast, unstructured guess.
#
# THIS IS A TEMPLATE. Copy it, edit the block between the two markers, and run the copy — never
# edit this file in place: tests/hitl-loop/test.sh runs the shipped copy with canned stdin to prove
# the helpers and the dump still work, and an edited original makes that proof about your bug
# instead of about the template.
#
# Usage:
#   cp skills/systematic-debugging/scripts/hitl-loop.template.sh /tmp/repro.sh
#   $EDITOR /tmp/repro.sh    # edit between the markers
#   bash /tmp/repro.sh
#
# Two helpers:
#   step "<instruction>"        → show the instruction, wait for Enter
#   capture VAR "<question>"    → show the question, read the answer into VAR
#
# `capture` echoes the value back into the terminal, where the agent reads it — so capture
# OBSERVATIONS ("did it throw?", "what did the banner say?") and leave anything with a credential in
# it, such as signing in, as a `step`. Everything the human types here is shown to the agent:
# redact secrets the way feedback-loop.md §6 requires, and never `capture` a password or a token.
#
# Bash 3.2 only (./scripts/parse-sweep.sh enforces it): no associative arrays, no `${var,,}`.
# When stdin is a pipe rather than a terminal, `read` consumes one line per prompt — which is how
# the golden suite drives it unattended.

set -euo pipefail

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _
}

capture() {
  # `local` before the assignments, and `printf -v` rather than `eval`: the answer is untrusted text
  # typed by a human, and `eval "$var=$answer"` would execute anything in it.
  local var="$1"
  local question="$2"
  local answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

# --- edit below ---------------------------------------------------------------------------------

step "Open the app at http://localhost:3000 and sign in."

capture ERRORED "Click the 'Export' button. Did it throw an error? (y/n)"

capture ERROR_MSG "Paste the error message (or 'none'):"

# --- edit above ---------------------------------------------------------------------------------

# The dump. One KEY=VALUE per line, nothing else on the line — this is the loop's output, and the
# agent reads its verdict from here. Keep it in sync with the `capture` calls above.
printf '\n--- Captured ---\n'
printf 'ERRORED=%s\n' "$ERRORED"
printf 'ERROR_MSG=%s\n' "$ERROR_MSG"
