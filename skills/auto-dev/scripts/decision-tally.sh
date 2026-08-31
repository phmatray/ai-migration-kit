#!/usr/bin/env bash
# decision-tally.sh — a markdown tally over decide.sh's event log (#318).
#
# WHY THIS EXISTS. scripts/decide.sh appends one JSON line per control-flow decision to
# `<repo>/.claude/decision-events.jsonl`, and its own header names the diagnostic nobody computes:
# "twenty `sync` events with ONE hash is one PR polled twenty times; twenty hashes is a systematic
# upstream defect." Nothing reads that log. This script does the counting so `auto-dev` Step 6 can
# paste a table into its mandatory `lessons` block instead of narrating impressions of a file no one
# opened.
#
# THIS SCRIPT DOES NOT JUDGE. It never emits "this is a bug" — only counts, ratios and the two flag
# labels below, which are printed thresholds, not verdicts (the same posture decide.sh takes toward
# the verdicts it dispatches: "the event log is how that gets measured over time rather than
# argued"). Reading a flagged row is the human's job.
#
# usage: decision-tally.sh [<events.jsonl>]
#        decision-tally.sh --help
#
# With no argument the log is resolved the same way decide.sh's own logger resolves it:
#   1. $KIT_DECISION_LOG, if set (absolute path expected, but read as given — see decide.sh);
#   2. <git toplevel of $PWD>/.claude/decision-events.jsonl;
#   3. no git toplevel, or the file at either of the above does not exist or is empty -> "no
#      decision events" is reported and this exits 0. A run outside the decision engine, or one
#      that made no decisions yet, is a valid state, not an error.
#
# MALFORMED LINES. A line that is not a JSON object, or is an object missing `decision`, `verdict`
# or `program`, cannot be tallied. It is counted in the footer's `malformed lines:` figure and
# otherwise ignored — never fatal, matching decide.sh's own "logging fails open" posture. A log with
# ONLY malformed lines (or none at all) is reported as "no decision events", same as an empty file.
#
# OUTPUT. One markdown table row per (decision, verdict) pair, in the order each pair first appears
# in the log — not alphabetical, so a chronological read (which combination showed up, and when)
# stays legible. Columns: events (row count), distinct inputs (unique `input_sha256`, a null counts
# as one bucket), programs (unique `program` hashes — more than one under a stable label usually
# means the program was edited mid-run). A footer line follows: malformed-line count, the log path
# used, and "events since program change" — how many of the log's events carry the SAME `program`
# hash as its most recent entry, i.e. how much history exists under the program's current text.
#
# FLAGS (printed thresholds, not verdicts — tune here, not in prose elsewhere):
#   repeat-poll  events >= 5  AND  distinct inputs <= events / 5
#                — the same input polled over and over (a PR checked twenty times is one PR, not
#                  twenty separate situations).
#   systematic   events >= 5  AND  distinct inputs >= events * 0.8  AND the verdict is one of the
#                non-terminal words {sync, wait, pending, fix-check}
#                — near-every event carries a DIFFERENT input yet still lands on a verdict that
#                  asks for another look; that pattern recurring across many distinct situations is
#                  a candidate defect upstream of the decision, not noise in any one of them.
#   Both are mutually exclusive by construction (repeat-poll needs a LOW distinct count, systematic
#   a HIGH one) and neither is a verdict — see decide.sh's own header on that distinction.
#
# Exit codes:
#   0  a table (or "no decision events") was printed, always — an unanswerable question about
#      decisions is not the same failure class as a broken decision, so this fails open.
#   2  usage error (more than one positional argument), or jq is missing (named, not just "failed").
#
# Registered in decisions/registry.json's `not_decisions`: this reports on decisions already made,
# it does not make one of its own.
set -euo pipefail

# Print the header block above as --help text, the way scripts/worktrees-ignored.sh and
# scripts/decide.sh do — grepped verbatim by ci.yml / the golden suite, so it stays the one place
# the thresholds are spelled out.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ $# -gt 1 ]; then
  echo "decision-tally: usage: decision-tally.sh [<events.jsonl>]" >&2
  echo "decision-tally: run with --help for the full contract" >&2
  exit 2
fi

# jq is probed before anything else touches the log, the same order decide.sh probes it in, so a
# jq-less host is told exactly what is missing rather than failing on some downstream symptom.
if ! command -v jq > /dev/null 2>&1; then
  echo "decision-tally: jq is required and was not found on PATH" >&2
  exit 2
fi

LOG="${1:-}"
if [ -z "$LOG" ]; then
  LOG="${KIT_DECISION_LOG:-}"
fi
if [ -z "$LOG" ]; then
  TOP=$(git rev-parse --show-toplevel 2> /dev/null) || TOP=""
  if [ -n "$TOP" ]; then
    LOG="$TOP/.claude/decision-events.jsonl"
  fi
fi

if [ -z "$LOG" ] || [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; then
  echo "no decision events"
  exit 0
fi

# Read the log line by line rather than handing it whole to `jq -s`: a single malformed line would
# otherwise abort the WHOLE parse, exactly the "must never be fatal" case this script exists to
# avoid. Each line is validated on its own; only the survivors are slurped for the tally below.
malformed=0
valid_lines=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  if printf '%s' "$line" \
    | jq -e 'type == "object" and (.decision|type) == "string" and (.verdict|type) == "string" and has("program")' \
    > /dev/null 2>&1
  then
    valid_lines+=("$line")
  else
    malformed=$((malformed + 1))
  fi
done < "$LOG"

if [ "${#valid_lines[@]}" -eq 0 ]; then
  echo "no decision events"
  exit 0
fi

JQPROG=$(mktemp)
trap 'rm -f "$JQPROG"' EXIT
cat > "$JQPROG" <<'JQ'
def padr(w): tostring as $s | $s + (" " * ([w - ($s|length), 0] | max));
def padl(w): tostring as $s | (" " * ([w - ($s|length), 0] | max)) + $s;

. as $events
| (reduce $events[] as $x ({order: [], map: {}};
      ($x.decision + " " + $x.verdict) as $k
      | if (.map | has($k))
        then .map[$k] += [$x]
        else (.order += [$k]) | (.map[$k] = [$x])
        end
    )) as $g
| ($g.order | map($g.map[.])) as $groups
| ($groups | map({
      decision: .[0].decision,
      verdict:  .[0].verdict,
      events:   length,
      distinct: (map(.input_sha256 // null) | unique | length),
      programs: (map(.program // null) | unique | length)
    } | . + {
      flag: (
        if (.events >= 5 and .distinct <= (.events / 5)) then "repeat-poll"
        elif (.events >= 5 and .distinct >= (.events * 0.8)
              and (.verdict as $v | ["sync","wait","pending","fix-check"] | index($v) != null))
        then "systematic"
        else "" end
      )
    })
  ) as $rows
| ["decision","verdict","events","distinct inputs","programs","flag"] as $headers
| [false,false,true,true,true,false] as $rightalign
| ($rows | map([.decision, .verdict, (.events|tostring), (.distinct|tostring), (.programs|tostring), .flag]))
    as $cellrows
| ([ range(0;6) | . as $i
     | (([$headers[$i]] + ($cellrows | map(.[$i]))) | map(length) | max) + 2
   ]) as $widths
| ([ range(0;6) | . as $i
     | if $rightalign[$i] then ("-" * ($widths[$i] - 1)) + ":" else ("-" * $widths[$i]) end
   ]) as $divcells
| ("|" + ($divcells | join("|")) + "|") as $dividerline
| ([ range(0;6) | . as $i
     | ($headers[$i]) as $c
     | if $rightalign[$i] then ($c | padl($widths[$i] - 2)) else ($c | padr($widths[$i] - 2)) end
   ]) as $headcells
| ("| " + ($headcells | join(" | ")) + " |") as $headerline
| ($cellrows | map(
      . as $row
      | ([ range(0;6) | . as $i
            | $row[$i]
            | if $rightalign[$i] then padl($widths[$i] - 2) else padr($widths[$i] - 2) end
         ])
      | "| " + join(" | ") + " |"
    )
  ) as $datalines
| (if ($events|length) > 0 then ($events[-1].program // null) else null end) as $lastprog
| ($events | map(select((.program // null) == $lastprog)) | length) as $sincechange
| ("malformed lines: " + ($malformed|tostring)
   + " · log: " + $logpath
   + " · events since program change: " + ($sincechange|tostring)) as $footer
| ([$headerline, $dividerline] + $datalines + [$footer]) | join("\n")
JQ

printf '%s\n' "${valid_lines[@]}" \
  | jq -s -r --argjson malformed "$malformed" --arg logpath "$LOG" -f "$JQPROG"
