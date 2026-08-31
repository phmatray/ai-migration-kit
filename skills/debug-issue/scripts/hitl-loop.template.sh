#!/usr/bin/env bash
# Human-in-the-loop reproduction loop — the last rung of feedback-loop.md's ladder.
#
# Ported from mattpocock/skills (MIT), engineering/diagnosing-bugs.
#
# WHY THIS EXISTS. Some bugs only appear when a human clicks: an SSO flow, a hardware dialog, a
# device you cannot automate. The temptation there is to give up on a feedback loop and start
# hypothesising from the code — the exact failure `debug-issue` prevents. So don't drop the
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
#   cp skills/debug-issue/scripts/hitl-loop.template.sh /tmp/repro.sh
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
# Written for bash 3.2 — no associative arrays, no `${var,,}` — because the kit's own scripts are.
# Nothing enforces that automatically (`./scripts/parse-sweep.sh` checks heredoc quoting, and says
# itself that its `bash -n` half proves nothing about 3.2 when run on a modern bash), so keep it
# true by hand if you extend the helpers.
#
# When stdin is a pipe rather than a terminal, `read` consumes one line per prompt — which is how
# the golden suite drives it unattended. Running out of input is NOT fatal: the reads tolerate EOF
# and the dump still prints, marking what was never answered, because a loop that collected four
# answers and then exited silently on the fifth would throw away the four.

set -euo pipefail

# The dump runs from an EXIT trap, so the answers survive an early exit — a `set -e` abort, an
# interrupted human, or stdin running out one prompt short. Every value is expanded with `:-` for
# the same reason: under `set -u` an unanswered variable would abort the dump itself, which is the
# one thing here that must never fail.
dump() {
  local rc=$?
  printf '\n--- Captured ---\n'
  printf 'ERRORED=%s\n' "${ERRORED:-<unanswered>}"
  printf 'ERROR_MSG=%s\n' "${ERROR_MSG:-<unanswered>}"
  exit "$rc"
}
trap dump EXIT

step() {
  printf '\n>>> %s\n' "$1"
  # `|| true`: EOF on a piped stdin must not abort the run under `set -e` — see the header.
  read -r -p "    [Enter when done] " _ || true
}

capture() {
  # The locals are prefixed because `printf -v "$1"` writes into THIS function's scope: a template
  # author who captures into a variable named `var`, `question` or `answer` would otherwise write
  # the local, lose the value at `return`, and see the dump report it unanswered.
  local _hitl_var="$1"
  local _hitl_question="$2"
  local _hitl_answer=''
  printf '\n>>> %s\n' "$_hitl_question"
  read -r -p "    > " _hitl_answer || true
  # `printf -v`, never `eval`: the answer is untrusted text typed by a human, and
  # `eval "$var=$answer"` would execute whatever is in it.
  printf -v "$_hitl_var" '%s' "$_hitl_answer"
}

# --- edit below ---------------------------------------------------------------------------------

step "Open the app at http://localhost:3000 and sign in."

capture ERRORED "Click the 'Export' button. Did it throw an error? (y/n)"

capture ERROR_MSG "Paste the error message (or 'none'):"

# --- edit above ---------------------------------------------------------------------------------

# Nothing to print here: `dump` above is the output, and it runs on every exit path. When you add a
# `capture`, add its line to `dump` — one KEY=VALUE per line, nothing else on the line, because
# that dump is what the agent reads its verdict from.
