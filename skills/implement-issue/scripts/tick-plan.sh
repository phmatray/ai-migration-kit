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
# Usage:
#   tick-plan.sh --repo <owner/repo> --issue <n> --before <file> --after <file>
#                [--comment-id <id>] [--dry-run]
#
#   --before   the body exactly as fetched, before any flip (the restore copy)
#   --after    the same body with this task's boxes flipped
#   --comment-id  plan lives in a comment (numeric REST id) instead of the issue description
#   --dry-run  validate and print the payload; touch nothing on GitHub
#
# Exits non-zero, having called nothing, on any failed check.

set -euo pipefail

die() { printf 'tick-plan: REFUSED — %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

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

if ! gh api "$endpoint" -X PATCH --input "$payload_file" >/dev/null; then
  die "the PATCH to $endpoint failed. The body was NOT changed; intact copy: $BEFORE"
fi

# Verify against what GitHub now actually holds — a successful PATCH is not proof of content.
if got=$(gh api "$endpoint" --jq .body 2>/dev/null); then
  if [ -z "${got//[[:space:]]/}" ]; then
    printf 'tick-plan: ALERT — %s now has an EMPTY body. Restore at once from %s\n' \
      "$endpoint" "$BEFORE" >&2
    exit 1
  fi
  if [ "$got" != "$(cat "$AFTER")" ]; then
    printf 'tick-plan: ALERT — %s does not match what was sent (concurrent edit?).\n' "$endpoint" >&2
    printf '           Pre-edit copy for restore: %s\n' "$BEFORE" >&2
    exit 1
  fi
else
  printf 'tick-plan: WARNING — PATCH reported success but the read-back failed; content unverified.\n' >&2
fi

printf 'tick-plan: %s — %s box(es) ticked, %s/%s done, body verified intact (%s bytes)\n' \
  "$endpoint" "$flipped" "$after_done" "$(( after_done + after_todo ))" "$after_bytes"
