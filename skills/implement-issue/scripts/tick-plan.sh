#!/usr/bin/env bash
# tick-plan.sh — write a checkbox-flipped plan back to a GitHub issue or comment, fail-closed.
#
# Replaces the recipe that destroyed two live issue bodies (Koine#1813):
#
#     jq -Rs '{body: .}' /tmp/plan-$ISSUE.md | gh api .../issues/$ISSUE -X PATCH --input -
#
# Measured failure modes of that pipeline:
#   * plan file MISSING → jq exits 2 but still prints a well-formed {"body": ""}; the pipeline's
#     exit status is gh's, so it exits 0. The issue body is wiped, silently.
#   * plan file EMPTY   → jq exits 0 and prints {"body": ""}. `set -o pipefail` does NOT catch
#     this one. Same wipe, and no non-zero status anywhere in the pipeline.
# So the payload reaching GitHub is never malformed — it is a perfectly valid empty body, which
# `gh` applies faithfully. Guarding the *transport* cannot help; the body itself must be checked.
#
# The check is exact rather than heuristic, because ticking a box is a one-character substitution:
# `- [ ]` → `- [x]` preserves the body byte for byte apart from that character. So this script
# refuses unless the new body is the old one with checkbox characters — and nothing else — changed.
#
# THE WRITE CONTRACT: the read-back, not the PATCH's exit status, decides the verdict.
#
# The pipe was the last surviving piece of that original recipe, and it was expensive: `gh api …
# --input -` fed from `printf | gh` took 25–35 MINUTES to return on a ~30KB body that GitHub had
# already stored in seconds (#113). So the payload now travels in a FILE, and EVERY `gh` call runs
# under a deadline — TICK_PLAN_PATCH_TIMEOUT seconds, default 60, implemented in pure bash because
# stock macOS ships no `timeout(1)`. Both calls, not just the write: bounding one leg only
# relocates the stall to the other, and expiry on the write is a deliberate handover to the read-
# back, so the bounded path guarantees the unbounded one runs next (#135). Killing a call does not
# un-send it, so expiry is a handover rather than a failure — and a read-back that was cut short is
# a read-back that FAILED, since either way the authority did not answer:
#
#   PATCH returns 0, stored body matches         → success
#   PATCH returns 0, stored body differs         → ALERT, exit 1
#   PATCH returns 0, read-back failed or bounded → WARNING, rc 0 — content unverified
#   PATCH bounded,   stored body matches         → success, and the output says the call was bounded
#   PATCH bounded,   stored body differs         → ALERT, exit 1
#   PATCH bounded,   read-back failed or bounded → ALERT, exit 1 — nothing confirms anything either way
#   PATCH exits non-zero on its own              → REFUSED; nothing was sent
#   payload validation fails                     → REFUSED; nothing was sent, nothing was bounded
#
# The deadline bounds the whole JOB, not the one pid: it launches under `set -m` so the call gets a
# process group of its own and the escalation signals the group. Killing only the pid leaves a
# descendant holding the inherited stdout/stderr, and a caller reading this script through a pipe
# then waits out the very call the deadline reported bounding (#135).
#
# Usage:
#   tick-plan.sh --repo <owner/repo> --issue <n> --before <file> --after <file>
#                [--comment-id <id>] [--dry-run]
#
#   --before   the body exactly as fetched, before any flip (the restore copy)
#   --after    the same body with this task's boxes flipped
#   --comment-id  plan lives in a comment (numeric REST id) instead of the issue description
#   --dry-run  validate and print the payload; touch nothing on GitHub
#
#   TICK_PLAN_PATCH_TIMEOUT  seconds any single `gh` call may run before it is bounded (default 60).
#                            The name predates the read-back being bounded too; it is kept because
#                            the contract was published under it.
#
# Exits non-zero, having called nothing, on any failed check.

set -euo pipefail

die() { printf 'tick-plan: REFUSED — %s\n' "$*" >&2; exit 1; }

# Print the whole header, however long it grows — a hardcoded last line silently truncates the
# usage text the next time a paragraph is added above it. The header ends at the first blank line.
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

REPO=""; ISSUE=""; COMMENT_ID=""; BEFORE=""; AFTER=""; DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       REPO="${2:-}";       shift 2 ;;
    --issue)      ISSUE="${2:-}";      shift 2 ;;
    --comment-id) COMMENT_ID="${2:-}"; shift 2 ;;
    --before)     BEFORE="${2:-}";     shift 2 ;;
    --after)      AFTER="${2:-}";      shift 2 ;;
    --dry-run)    DRY_RUN=1;           shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ]   || die "--repo <owner/repo> is required"
[ -n "$ISSUE" ]  || die "--issue <n> is required"
[ -n "$BEFORE" ] || die "--before <file> is required (the pre-edit copy is the restore path)"
[ -n "$AFTER" ]  || die "--after <file> is required"

# How long the PATCH may run before it is bounded (see the write block). Checked here, next to the
# other arguments, so a junk value is caught long before anything could be sent.
PATCH_TIMEOUT="${TICK_PLAN_PATCH_TIMEOUT:-60}"
case "$PATCH_TIMEOUT" in
  ''|*[!0-9]*) die "TICK_PLAN_PATCH_TIMEOUT must be a whole number of seconds, got '$PATCH_TIMEOUT'" ;;
esac
[ "$PATCH_TIMEOUT" -ge 1 ] \
  || die "TICK_PLAN_PATCH_TIMEOUT must be at least 1 second, got '$PATCH_TIMEOUT'"

# ---------------------------------------------------------------- the body checks

[ -f "$BEFORE" ] || die "--before file does not exist: $BEFORE"
[ -f "$AFTER" ]  || die "--after file does not exist: $AFTER — the flip never produced a body"
[ -s "$BEFORE" ] || die "--before file is empty: $BEFORE (nothing to compare against; refusing to guess)"
[ -s "$AFTER" ]  || die "--after file is empty: $AFTER — this is the wipe; nothing sent"

# A plan heading in the old body must survive into the new one.
if grep -qE '^#+ .*[Ii]mplementation plan' "$BEFORE"; then
  grep -qE '^#+ .*[Ii]mplementation plan' "$AFTER" \
    || die "the plan heading is present in --before but gone from --after; nothing sent"
fi

before_bytes=$(wc -c < "$BEFORE" | tr -d ' ')
after_bytes=$(wc -c < "$AFTER" | tr -d ' ')
[ "$before_bytes" = "$after_bytes" ] || die \
  "body length changed ($before_bytes → $after_bytes bytes). Ticking a checkbox is a
             one-character substitution and cannot change the length — something rewrote the
             body. Nothing sent; the intact copy is $BEFORE"

# The decisive check: with every box forced back to unticked, the two bodies must be identical.
# Anything else that changed — a rewritten sentence, a lost section, a truncation that happens
# to preserve length — shows up here.
unticked_form() { sed -E 's/^([[:space:]]*[-*][[:space:]]+)\[[xX]\]/\1[ ]/' "$1"; }

if ! diff -q <(unticked_form "$BEFORE") <(unticked_form "$AFTER") >/dev/null; then
  {
    echo "tick-plan: REFUSED — --after differs from --before outside the checkboxes."
    echo "           Only '- [ ]' → '- [x]' flips are allowed here. Nothing sent."
    echo "           The intact copy is $BEFORE. Offending diff (checkbox state normalised away):"
    diff <(unticked_form "$BEFORE") <(unticked_form "$AFTER") | head -20 | sed 's/^/           /'
  } >&2
  exit 1
fi

count_boxes() { grep -cE "^[[:space:]]*[-*][[:space:]]+\[$1\]" "$2" 2>/dev/null || true; }

before_done=$(count_boxes '[xX]' "$BEFORE"); after_done=$(count_boxes '[xX]' "$AFTER")
before_todo=$(count_boxes ' '    "$BEFORE"); after_todo=$(count_boxes ' '    "$AFTER")

[ "$after_done" -gt "$before_done" ] || die \
  "no checkbox was ticked ($before_done → $after_done done). The intended edit did not land;
             pushing this would be a no-op that looks like progress. Nothing sent"

[ "$after_todo" -lt "$before_todo" ] || die \
  "the unticked count did not fall ($before_todo → $after_todo). Nothing sent"

flipped=$(( after_done - before_done ))
consumed=$(( before_todo - after_todo ))
[ "$flipped" -eq "$consumed" ] || die \
  "checkbox accounting does not balance: $flipped newly ticked but $consumed fewer unticked.
             A box was added, removed or un-ticked. Nothing sent"

# ---------------------------------------------------------------- payload

payload=$(jq -Rs '{body: .}' "$AFTER")
[ -n "$payload" ] || die "jq produced no payload. Nothing sent"

# Prove the payload round-trips to exactly the file we validated, before it can reach GitHub.
printf '%s' "$payload" | jq -e '(.body | length) > 0' >/dev/null \
  || die "the payload carries an empty body — the exact defect this guards. Nothing sent"
# `jq -j` and not `jq -r`: -r appends a newline of its own, which would make a faithful
# payload look corrupt (and, worse, a real trailing-newline change look faithful).
diff -q <(printf '%s' "$payload" | jq -j '.body') "$AFTER" >/dev/null \
  || die "the payload does not round-trip to --after. Nothing sent"

if [ -n "$COMMENT_ID" ]; then
  endpoint="repos/$REPO/issues/comments/$COMMENT_ID"
else
  endpoint="repos/$REPO/issues/$ISSUE"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'tick-plan: dry run — would PATCH %s (%s box(es) ticked, %s bytes)\n' \
    "$endpoint" "$flipped" "$after_bytes"
  printf '%s\n' "$payload"
  exit 0
fi

# ---------------------------------------------------------------- the call deadline, once

# THE one home for the deadline (#135). Runs its argv in the background, bounded to
# TICK_PLAN_PATCH_TIMEOUT seconds, escalating SIGTERM → 2s grace → SIGKILL, and reports both the
# command's exit status and whether the deadline had to fire.
#
# It is a function rather than two inline copies because both `gh` calls below need bounding, and
# hand-copied machinery is precisely what drifts — `tests/_lib.sh` exists because ten copies of a
# preamble had already diverged (#72). `timeout(1)` is absent on stock macOS, so the deadline is
# pure bash; that is what makes it the kind of block someone would otherwise paste twice.
#
#   run_bounded <stdout-file> <cmd> [args...]
#     <cmd>'s stdout goes to <stdout-file>; its stderr is left alone.
#     Sets RC      — the command's exit status, from `wait`.
#     Sets BOUNDED — 1 if the deadline fired, 0 if the command finished on its own.
run_bounded() {
  local out_file="$1"; shift

  # `set -m` gives the background job a process group of its own (pgid == pid), which is what lets
  # the escalation below signal the whole JOB rather than the single pid bash hands back. That
  # distinction is the difference between bounding this script and bounding the caller: a
  # descendant that outlives the kill still holds the stdout and stderr it inherited, so a caller
  # reading this script through a pipe blocks until the descendant exits — the full duration of the
  # very call the deadline just reported bounding. Measured at 4s to a file against 60s to a pipe
  # for one 2s deadline (#135). bash 3.2 ships no `setsid`, so job control is the way in.
  set -m
  "$@" > "$out_file" &
  local pid=$!
  set +m

  BOUNDED=0
  local deadline_at grace_until
  deadline_at=$(( $(date +%s) + PATCH_TIMEOUT ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline_at" ]; then
      # SIGTERM, then ESCALATE. A deadline that only asks politely is advisory: the `wait` below
      # blocks until the child really exits, so anything that ignores or blocks TERM would hold the
      # run open for exactly as long as the unbounded call did. SIGKILL cannot be ignored, which is
      # what makes the bound a bound.
      # Both signals go to the process GROUP (`-- -"$pid"`), falling back to the bare pid if the
      # group has already gone — the group is what carries the descendants holding the pipe.
      kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      grace_until=$(( $(date +%s) + 2 ))
      while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$grace_until" ]; do
        sleep 0.1 2>/dev/null || sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      fi
      BOUNDED=1
      break
    fi
    # Fine-grained where the platform allows it, so a healthy call pays ~0.1s, not a whole second.
    sleep 0.1 2>/dev/null || sleep 1
  done

  RC=0
  wait "$pid" 2>/dev/null || RC=$?
}

# ---------------------------------------------------------------- write, then read back

# The payload goes to gh in a FILE, not down a stdin pipe. `--input -` was the last piece of the
# recipe this script replaced still in place, and it is what made a PATCH of a ~30KB body take
# 25–35 minutes to return from a write GitHub had already applied in seconds (#113) — the same
# host reads the same issue back in 0.4s. A file has no pipe handshake to get stuck in.
payload_file=$(mktemp "${TMPDIR:-/tmp}/tick-plan-payload.XXXXXX") \
  || die "could not create a temp file for the payload. Nothing sent"
trap 'rm -f "$payload_file"' EXIT
printf '%s' "$payload" > "$payload_file"
[ -s "$payload_file" ] || die "the payload file came out empty. Nothing sent"

# The PATCH runs under the deadline above, because an unbounded one has stalled a run for half an
# hour (#113).
run_bounded /dev/null gh api "$endpoint" -X PATCH --input "$payload_file"
bounded=$BOUNDED
patch_rc=$RC

if [ "$bounded" -eq 1 ]; then
  # Killing the call does NOT un-send it: GitHub may well have stored the body already — that is
  # precisely the observed behaviour. So this is not a failure, it is a handover to the read-back.
  printf 'tick-plan: the PATCH to %s exceeded %ss and was bounded; the read-back decides.\n' \
    "$endpoint" "$PATCH_TIMEOUT" >&2
elif [ "$patch_rc" -ne 0 ]; then
  die "the PATCH to $endpoint failed. The body was NOT changed; intact copy: $BEFORE"
fi

# Verify against what GitHub now actually holds — a successful PATCH is not proof of content,
# and a bounded one is not proof of failure. Either way this read-back is the authority.
#
# It runs under the SAME deadline as the PATCH (#135). Bounding only the write does not remove
# #113's failure mode, it relocates it: expiry on the write is a deliberate handover to this call,
# so the bounded path *guarantees* this one runs next — and an unbounded authority is exactly
# where the stall then lands.
readback_file=$(mktemp "${TMPDIR:-/tmp}/tick-plan-readback.XXXXXX") \
  || die "could not create a temp file for the read-back"
trap 'rm -f "$payload_file" "$readback_file"' EXIT

# A wrapper, because run_bounded takes an argv and this leg keeps gh's own stderr suppressed.
quiet_gh() { gh "$@" 2>/dev/null; }

run_bounded "$readback_file" quiet_gh api "$endpoint" --jq .body
read_bounded=$BOUNDED
read_rc=$RC

# A read-back that was cut short is a read-back that FAILED: in both cases the authority did not
# answer, so both route to the outcome the contract already defines for "no answer" rather than to
# a fourth verdict. Decided BEFORE the body is looked at — a killed call leaves an empty or
# truncated file, and reading that as "GitHub now holds an empty body" would fire the loudest
# alarm in this script on no evidence whatsoever.
if [ "$read_bounded" -eq 0 ] && [ "$read_rc" -eq 0 ]; then
  got=$(cat "$readback_file")

  # `case`, and NOT `[ -z "${got//[[:space:]]/}" ]`. bash 3.2's pattern substitution is O(n^2) in
  # the subject length, and the subject here is the entire issue body. Measured against a live
  # 15.8KB body: 4KB took 5s, 8KB 33s, 15.8KB 247s — all of it pure CPU, *after* the PATCH has
  # already landed, and with no deadline over it because it is not a `gh` call at all. That is the
  # "hangs after a successful PATCH, needs kill -9" report behind #135, and it grows with every
  # box the plan gains. The glob answers the same question — is there one non-blank character? —
  # in constant time.
  body_is_blank=1
  case "$got" in *[![:space:]]*) body_is_blank=0 ;; esac

  if [ "$body_is_blank" -eq 1 ]; then
    printf 'tick-plan: ALERT — %s now has an EMPTY body. Restore at once from %s\n' \
      "$endpoint" "$BEFORE" >&2
    exit 1
  fi
  if [ "$got" != "$(cat "$AFTER")" ]; then
    if [ "$bounded" -eq 1 ]; then
      # Different cause, so different advice. After a call that was cut short, "restore from
      # --before" is the wrong move twice over: the write probably never landed (nothing to undo),
      # and if it lands a moment later the restore silently un-ticks it.
      printf 'tick-plan: ALERT — %s does not hold what was sent, and the PATCH was cut short at %ss,\n' \
        "$endpoint" "$PATCH_TIMEOUT" >&2
      printf '           so the likeliest reading is that the write never landed. RE-RUN the tick.\n' >&2
      printf '           Do NOT restore from %s — that would undo a write that may still arrive.\n' "$BEFORE" >&2
    else
      printf 'tick-plan: ALERT — %s does not match what was sent (concurrent edit?).\n' "$endpoint" >&2
      printf '           Pre-edit copy for restore: %s\n' "$BEFORE" >&2
    fi
    exit 1
  fi
elif [ "$bounded" -eq 1 ]; then
  # The one path with no evidence at all: the call was cut short AND the authority did not answer
  # — whether it failed outright or was itself bounded, which are the same thing here.
  # Reporting success would be a claim with nothing behind it.
  printf 'tick-plan: ALERT — the PATCH was bounded at %ss and the read-back failed or was bounded,\n' \
    "$PATCH_TIMEOUT" >&2
  printf '           so nothing confirms what %s now holds. Re-run to find out; pre-edit copy: %s\n' \
    "$endpoint" "$BEFORE" >&2
  exit 1
else
  printf 'tick-plan: WARNING — PATCH reported success but the read-back failed or was bounded;\n' >&2
  printf '           content unverified.\n' >&2
  verified=0
fi

# The summary line must not claim more than was actually established: on the WARNING path above
# nothing was read back, so "verified intact" would be the kind of unbacked claim this whole
# script exists to prevent.
if [ "${verified:-1}" -eq 1 ]; then
  state="body verified intact"
else
  state="body NOT verified — the read-back failed or was bounded"
fi

bounded_note=""
if [ "$bounded" -eq 1 ]; then
  bounded_note=" [PATCH bounded at ${PATCH_TIMEOUT}s; verdict from the read-back]"
fi

printf 'tick-plan: %s — %s box(es) ticked, %s/%s done, %s (%s bytes)%s\n' \
  "$endpoint" "$flipped" "$after_done" "$(( after_done + after_todo ))" "$state" "$after_bytes" "$bounded_note"
