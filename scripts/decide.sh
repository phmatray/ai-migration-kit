#!/usr/bin/env bash
# decide.sh — run a registered decision and print its verdict (#208).
#
# usage: decide.sh <decision-id> [--json] [<state.json>]
#        decide.sh --program <decision-id>
#        decide.sh --list
#        decide.sh --help
#
# WHY THIS EXISTS. This kit holds ~3k lines of tested guard code and ~5.6k lines of agent-facing
# prose, and the prose drives. `skills/merge-pr/scripts/merge-verdict.sh` encodes the whole Step 4
# precedence rule, is pinned by fixtures, is wired into CI — and nothing invoked it. SKILL.md
# restated the same rule as a table and the agent applied THAT, by hand. The two drifted once
# already: a jq object-construction rename made the documented `gh api compare` emit `.behind`
# while the script read `.behind_by`, so the guard read null forever. A human reviewer caught it.
#
# So a control-flow decision now gets ONE id, ONE program and ONE home, listed in
# decisions/registry.json. This script is the only way to run one. The agent INVOKES a decision;
# prose EXPLAINS it and may not RESTATE it. scripts/decision-check.py is the guard that refuses a
# second copy, an owner that stopped invoking, a shape that stopped building what the program
# reads, and a markdown table that re-enumerates the states the program tests.
#
# WHAT IT DOES NOT DO, said here because a header promising more than the code performs is worse
# than no header — it stops the next reader adding the check that is missing:
#   * it does not discover decisions. Everything it can run is listed in the registry by hand, and
#     nothing here proves that everything real is listed. That counter-guard is slice two.
#   * it does not validate the SHAPE block. `shape` is read by decision-check.py (R6) only; a shape
#     that has stopped emitting what the program reads is caught at build time, not at run time.
#   * it does not judge a verdict. A word inside the declared vocabulary is reported as-is; whether
#     `wait` is the right answer is the caller's problem, and the event log is how that gets
#     measured over time rather than argued.
#
# ORDER OF OPERATIONS, each step where it is because of a measured hole:
#   1. KIT_ROOT is resolved from $0 THROUGH SYMLINKS. A plugin install reaches this file by link
#      and `pwd -P` alone canonicalizes the directory, never the link, so it would look for the
#      registry beside the LINK. Never $PWD — the one deliberate exception is the event log, which
#      is about the CONSUMER repo the agent is standing in.
#   2. --help / --list / --program answer without touching stdin.
#   3. jq is probed BEFORE stdin is read. merge-verdict.sh probes it after, so on a jq-less host it
#      blocks on the pipe forever instead of naming the missing tool.
#   4. an unknown id names itself, the registry file, and every id that IS registered.
#   5. the program is materialized before the input is read, so a missing script or a duplicated
#      marker is reported instead of consuming the caller's pipe first.
#   6. EMPTY INPUT IS EXIT 2. An empty verdict that reads as a pass is the failure this whole kit
#      keeps re-finding; no verdict is not a pass.
#   7. anything the program writes to stderr is relayed VERBATIM. Only the verdict reaches stdout,
#      which is what makes `V=$(decide.sh merge.step4 <<< "$STATE")` safe to write in a SKILL.md
#      fence.
#   8. a program that produces no .verdict, or a word outside the declared vocabulary, EXITS 1.
#      A broken program must not read as a pass either.
#
# THE EVENT LOG (fail-open, on purpose). One JSON object per decision, appended with a single
# `printf >>` so a lone append is atomic — this kit runs N auto-dev workers in parallel and a
# read-modify-write JSON array would lose events. Fields: v, ts, decision, verdict, rule, program
# (git hash-object of the program TEXT, so counts reset when the program is edited rather than
# polluting across versions) and input_sha256 (twenty `sync` events with ONE hash is one PR polled
# twenty times; twenty hashes is a systematic upstream defect). Location, first hit wins:
#   1. $KIT_DECISION_LOG, absolute — how the suites point it into their scratch dir;
#   2. <git toplevel of $PWD>/.claude/decision-events.jsonl — the CONSUMER repo, because the
#      decision is about THAT repo's PR and a plugin-installed kit directory may be read-only;
#   3. no git toplevel -> nothing is logged, silently. A decision made outside a repo is valid.
# It stays out of git by TWO independent halves, because either alone has failed here before:
# the .gitignore rule, and a `git check-ignore` probe run before EVERY append. #43 exists because
# a stray `git add -A` committed a repo into itself, and this is a file agents will create in
# OTHER PEOPLE'S repos where our .gitignore has no reach.
# DECIDING FAILS CLOSED; LOGGING FAILS OPEN. An unignorable log, an uncreatable directory or a
# full disk suppresses the event and changes neither stdout nor the exit code. An engine that
# refuses to decide because its telemetry is broken is strictly worse than the prose it replaced.
#
# Exit codes:
#   0  a verdict was produced and it is in the decision's declared vocabulary
#   1  REFUSED — the program produced no .verdict, or a word outside the vocabulary.
#      A broken program must not read as a pass.
#   2  no verdict is possible — unknown id; registry unreadable or not JSON; empty `decisions`;
#      home file unreadable; marker absent or non-unique; program path missing or not executable;
#      jq missing; jq failed on the input (malformed JSON, non-object top level); EMPTY INPUT;
#      two positional paths; usage errors.
set -euo pipefail

# Print the header block above as the help text, the way scripts/worktrees-ignored.sh does — a
# hardcoded line range there silently stops documenting the exit codes, and ci.yml greps --help
# for exactly that string.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

die() {
  _rc="$1"; shift
  printf 'decide: %s\n' "$1" >&2
  shift
  while [ $# -gt 0 ]; do printf '  %s\n' "$1" >&2; shift; done
  exit "$_rc"
}
warn() { printf 'decide: %s\n' "$1" >&2; }

# ------------------------------------------------------------------------------- 1. self-location
#
# $0 through any symlinks first. No `readlink -f` — macOS's readlink has no -f. Lifted verbatim
# from skills/implement-issue/scripts/guarded-commit.sh, which is where this loop was debugged.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
# The `||` fallback is not decoration: this is a plain assignment from a command substitution, so
# under `set -e` a failing cd would kill the script THERE with exit 1 and not a word.
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/.." && pwd -P) || KIT_ROOT="$(dirname -- "$SELF")/.."
REGISTRY="$KIT_ROOT/decisions/registry.json"

# ------------------------------------------------------------------------------ 2. the arguments
MODE=run
ID=""
STATE_PATH=""
HAVE_PATH=0
WANT_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list)    MODE=list; shift ;;
    --program) MODE=program; shift ;;
    --json)    WANT_JSON=1; shift ;;
    -*)        die 2 "unexpected option: $1" "usage: decide.sh <decision-id> [--json] [<state.json>]" ;;
    *)
      if [ -z "$ID" ]; then
        ID="$1"
      elif [ "$HAVE_PATH" -eq 0 ]; then
        STATE_PATH="$1"; HAVE_PATH=1
      else
        # merge-verdict.sh answers \$1 and ignores \$2 in silence, exit 0 — a second state file is
        # a caller who believes both were judged. It never was.
        die 2 "two positional paths: '$STATE_PATH' and '$1'" \
              "One decision reads ONE state. Run it twice if you meant two."
      fi
      shift ;;
  esac
done

# ------------------------------------------------------- 3. jq, BEFORE anything can read the pipe
command -v jq > /dev/null 2>&1 || \
  die 2 "jq is missing — it is a \`required\` prerequisite in requirements.json" \
        "Every registered decision is read, run or checked through it."

# ---------------------------------------------------------------------------- 4. the registry
[ -r "$REGISTRY" ] || \
  die 2 "cannot read $REGISTRY" \
        "The registry is the list of decisions this kit can run. Without it there is nothing to run."
jq -e . "$REGISTRY" > /dev/null 2>&1 || \
  die 2 "$REGISTRY is not valid JSON"
N_DECISIONS=$(jq -r '(.decisions // []) | length' "$REGISTRY")
[ "$N_DECISIONS" -gt 0 ] 2>/dev/null || \
  die 2 "$REGISTRY declares no decisions" \
        "An empty registry is not \"nothing to do\" — it is a registry that lost its contents."

known_ids() { jq -r '.decisions[].id' "$REGISTRY" | sed 's/^/  - /'; }

if [ "$MODE" = list ]; then
  # <id> <kind> <path-or-home> <word>[,<word>...]. Touches no program.
  jq -r '.decisions[]
         | [ .id,
             .program.kind,
             (.program.path // .program.home),
             (.verdict.vocabulary | join(",")) ]
         | @tsv' "$REGISTRY"
  exit 0
fi

[ -n "$ID" ] || die 2 "no decision id given" "usage: decide.sh <decision-id> [--json] [<state.json>]"

N_ROWS=$(jq -r --arg id "$ID" '[ .decisions[] | select(.id == $id) ] | length' "$REGISTRY")
if [ "$N_ROWS" = "0" ]; then
  printf 'decide: unknown decision id: %s\n' "$ID" >&2
  printf '  It is not in %s. Registered ids:\n' "$REGISTRY" >&2
  known_ids >&2
  exit 2
fi
if [ "$N_ROWS" != "1" ]; then
  die 2 "decision id '$ID' is declared $N_ROWS times in $REGISTRY" \
        "One id, one program, one home. Two rows is two answers to the same question."
fi

ROW=$(jq -c --arg id "$ID" '.decisions[] | select(.id == $id)' "$REGISTRY")
row_field() { printf '%s' "$ROW" | jq -r "$1"; }

KIND=$(row_field '.program.kind')
SOURCE=$(row_field '.verdict.source')
STDIN_WANTED=$(row_field 'if (.stdin // true) then "yes" else "no" end')

# `verdict.source` is validated against a closed set today so that a second kind — an `exit-map`
# decision, #170's local half and #163 — becomes a registry row later rather than a redesign.
# It is NOT implemented; a row that declares it must go red here and not be quietly run as JSON.
[ "$SOURCE" = "stdout-json" ] || \
  die 2 "decision '$ID' declares verdict.source='$SOURCE', which this dispatcher cannot run" \
        "Only 'stdout-json' exists in slice one. 'exit-map' is the planned extension point and is" \
        "deliberately NOT implemented — implement it here before registering a row that needs it."

# ------------------------------------------------------------------- 5. materialize the program
#
# Before the input is read, so a missing script or a duplicated marker is reported rather than
# swallowing the caller's pipe first.
PROG_FILE=""
PROG_TMP=""
cleanup() { [ -n "$PROG_TMP" ] && rm -f "$PROG_TMP"; return 0; }
trap cleanup EXIT

case "$KIND" in
  exec)
    PROG_REL=$(row_field '.program.path')
    PROG_FILE="$KIT_ROOT/$PROG_REL"
    [ -f "$PROG_FILE" ] || \
      die 2 "decision '$ID' names a program that does not exist: $PROG_REL" \
            "Registered at $REGISTRY. Restore the file, or remove the row."
    [ -x "$PROG_FILE" ] || \
      die 2 "decision '$ID' names a program that is not executable: $PROG_REL" \
            "chmod +x it — and \`git update-index --chmod=+x\` it, or the index keeps the old mode."
    ;;
  block)
    HOME_REL=$(row_field '.program.home')
    MARKER=$(row_field '.program.marker')
    HOME_FILE="$KIT_ROOT/$HOME_REL"
    [ -r "$HOME_FILE" ] || \
      die 2 "decision '$ID' declares its home as $HOME_REL, which cannot be read" \
            "The program lives in that file, between its markers. There is nothing to extract."

    # Matched as FIXED strings on the PREFIX, so free text may follow before the closing arrows —
    # the shipped block carries an em-dash sentence naming the suite that runs it.
    BEGIN_MARK="# >>> decision $MARKER"
    END_MARK="# <<< decision $MARKER"
    n_begin=$(grep -c -F -- "$BEGIN_MARK" "$HOME_FILE" || true)
    n_end=$(grep -c -F -- "$END_MARK" "$HOME_FILE" || true)
    if [ "$n_begin" != "1" ] || [ "$n_end" != "1" ]; then
      die 2 "$HOME_REL must carry EXACTLY ONE marked program for '$ID'" \
            "found $n_begin '$BEGIN_MARK' and $n_end '$END_MARK'" \
            "Two blocks means two homes for the gate, and a gate with two homes drifts."
    fi

    PROG_TMP=$(mktemp "${TMPDIR:-/tmp}/decide.XXXXXX") || \
      die 2 "cannot create a scratch file to extract the program for '$ID' into"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
      index($0, b) { inside = 1 }
      inside       { print }
      inside && index($0, e) { exit }
    ' "$HOME_FILE" > "$PROG_TMP"
    [ -s "$PROG_TMP" ] || \
      die 2 "extracted an empty program for '$ID' from $HOME_REL"
    PROG_FILE="$PROG_TMP"
    ;;
  *)
    die 2 "decision '$ID' declares program.kind='$KIND', which this dispatcher does not know" \
          "Known kinds: exec (a script) and block (a marked jq program inside a reference file)."
    ;;
esac

# --program is the ONE home for extraction in this repo. tests/merge-gate/test.sh and
# scripts/decision-check.py both call it instead of re-implementing the awk, so an extraction bug
# reddens there too rather than being papered over by a second implementation that agrees.
if [ "$MODE" = program ]; then
  cat "$PROG_FILE"
  exit 0
fi

# ------------------------------------------------------------------------------ 6. the input
INPUT=""
if [ "$STDIN_WANTED" = yes ]; then
  if [ "$HAVE_PATH" -eq 1 ]; then
    [ -r "$STATE_PATH" ] || die 2 "cannot read state file: $STATE_PATH"
    INPUT=$(cat "$STATE_PATH")
  else
    INPUT=$(cat)
  fi
  [ -n "$INPUT" ] || \
    die 2 "empty input for '$ID' — no verdict is not a pass" \
          "A failed query and a state with nothing in it spell the same empty string, and one of" \
          "them merges. Feed the decision a state, or handle the query failure above this call."
fi

# ------------------------------------------------------------------------------ 7. run it
#
# Command substitution redirects stdout ONLY, so whatever the program writes to stderr flows
# through to this script's stderr verbatim, unbuffered and unquoted.
rc=0
if [ "$KIND" = exec ]; then
  OUT=$(printf '%s' "$INPUT" | "$PROG_FILE") || rc=$?
else
  OUT=$(printf '%s' "$INPUT" | jq -f "$PROG_FILE") || rc=$?
fi
if [ "$rc" -ne 0 ]; then
  die 2 "the program for '$ID' failed (exit $rc) on the given input" \
        "Malformed JSON, or a top level the program cannot index, produces this. Its own error is" \
        "above, verbatim."
fi

# --------------------------------------------------------------- 8. the verdict, or a REFUSAL
VERDICT=$(printf '%s' "$OUT" | jq -r '
  select(type == "object")
  | select((.verdict | type) == "string")
  | select((.rule    | type) == "string")
  | .verdict' 2>/dev/null || true)

if [ -z "$VERDICT" ]; then
  printf 'decide: REFUSED — the program for %s produced no usable verdict.\n' "$ID" >&2
  printf '  Expected a JSON object on stdout carrying a string .verdict and a string .rule.\n' >&2
  printf '  Got: %s\n' "$OUT" >&2
  printf '  A program that answers nothing must not read as a pass.\n' >&2
  exit 1
fi

IN_VOCAB=$(printf '%s' "$ROW" | jq -r --arg v "$VERDICT" \
  'if (.verdict.vocabulary | index($v)) then "yes" else "no" end')
if [ "$IN_VOCAB" != yes ]; then
  printf 'decide: REFUSED — %s answered %s, which is not in its declared vocabulary.\n' "$ID" "$VERDICT" >&2
  printf '  Declared: %s\n' "$(printf '%s' "$ROW" | jq -r '.verdict.vocabulary | join(" ")')" >&2
  printf '  Either the program shipped a new word without registering it, or the registry lost one.\n' >&2
  printf '  Register it in %s and give it a caller before it can be answered.\n' "$REGISTRY" >&2
  exit 1
fi

RULE=$(printf '%s' "$OUT" | jq -r '.rule')

# ------------------------------------------------------------------------------- 9. the event
#
# python3's hashlib rather than a checksum binary: `shasum` is macOS-only, `sha256sum` is GNU-only,
# and python3 is already `required` in requirements.json.
INPUT_SHA=null
if [ "$STDIN_WANTED" = yes ]; then
  _digest=$(printf '%s' "$INPUT" | python3 -c \
    'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' \
    2>/dev/null) || _digest=""
  [ -n "$_digest" ] && INPUT_SHA="\"$_digest\""
fi
PROG_HASH=$(git hash-object "$PROG_FILE" 2>/dev/null) || PROG_HASH=""
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ----------------------------------------------------------------------- 10. append, fail-OPEN
log_event() {
  _log="${KIT_DECISION_LOG:-}"
  if [ -z "$_log" ]; then
    _top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _top=""
    # No repository around the caller: nothing is logged, and that is not an error. A decision
    # made outside a repo is still a decision.
    [ -n "$_top" ] || return 0
    _log="$_top/.claude/decision-events.jsonl"
  fi
  case "$_log" in
    /*) ;;
    *)  warn "KIT_DECISION_LOG must be an absolute path; got '$_log'. No event written."; return 0 ;;
  esac

  _dir=$(dirname "$_log")
  mkdir -p "$_dir" 2>/dev/null || {
    warn "cannot create $_dir — the event is dropped, the verdict stands."; return 0; }

  # The second of the two independent halves. `git check-ignore` on the PATH, never a grep of a
  # .gitignore: our .gitignore has no reach inside a consumer's repo, and #43 exists because a
  # stray `git add -A` committed a repo into itself.
  _logtop=$(git -C "$_dir" rev-parse --show-toplevel 2>/dev/null) || _logtop=""
  if [ -n "$_logtop" ]; then
    git -C "$_logtop" check-ignore -q "$_log" 2>/dev/null || {
      warn "refusing to write $_log — git does not ignore it, and an agent's telemetry must never
      become a commit in someone else's repository. Add the path to that repo's .gitignore (or
      point \$KIT_DECISION_LOG somewhere ignored). The verdict below is unaffected."
      return 0; }
  fi

  printf '{"v":1,"ts":"%s","decision":"%s","verdict":"%s","rule":"%s","program":"%s","input_sha256":%s}\n' \
    "$TS" "$ID" "$VERDICT" "$RULE" "$PROG_HASH" "$INPUT_SHA" >> "$_log" 2>/dev/null || {
    warn "cannot append to $_log — the event is dropped, the verdict stands."; return 0; }
  return 0
}
log_event

# ------------------------------------------------------------------------------ 11. stdout
if [ "$WANT_JSON" -eq 1 ]; then
  printf '%s' "$OUT" | jq -c .
else
  printf '%s\n' "$VERDICT"
fi
exit 0
