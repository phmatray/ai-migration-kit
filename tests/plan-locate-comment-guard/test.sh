#!/usr/bin/env bash
# Golden test for the plan-locate comment scan's two guards (#278, #286).
#
# §2's `PLAN_SRC = comment` branch (skills/implement-issue/references/github-mechanics.md) fetches
# every comment on an issue via `gh api .../comments --paginate --slurp`, then filters for the plan
# marker comment or, failing that, the latest comment with checkbox lines. Both filters ran
# `select(.body | contains(...))` directly on `.body`, which throws if `.body` is ever `null` —
# exactly the way `test()` did in the pre-#259 PR-existence guard (#278 fixed that with `.body // ""`).
#
# Unlike #259's confirmed case, the null-body crash is DEFENSIVE rather than a proven live crash:
# GitHub's REST OpenAPI schema types `issue-comment.body` as a plain non-nullable `string` (checked
# directly against `components.schemas.issue-comment.properties.body` in
# https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.json),
# unlike `issue.body` (and PR bodies, which reuse the issue schema) which IS declared
# `nullable: true` — the field #259 actually fixed. So a `null` comment body is not known-reachable
# through this endpoint today. The guard is still worth having (cheap, and it matches the sibling
# call site's shape), but this suite pins defensive behavior against a hypothetical input, not a
# reproduction of an observed failure.
#
# #286: separately from the null-body defense, `... | last | .id` renders a genuine "nothing
# matched" as the literal jq value `null`, and `jq -r` prints that as the FOUR-CHARACTER STRING
# "null" — not empty output. The surrounding bash gates on `[ -z "$PLAN_COMMENT_ID" ]`, which is
# false for the string "null", so the fallback scan and the "no plan" stop never fire. This is not
# specific to a null *body*: it reproduces on any zero-match comment set, `null` body or not. The
# fix appends `// empty` so a genuine non-match prints nothing, and `$(...)` captures the empty
# string `-z` already expects.
#
# The programs under test are NOT copied here. They are EXTRACTED from the two marked blocks inside
# skills/implement-issue/references/github-mechanics.md §2 and run verbatim via `jq -f`, so the thing
# this suite proves green is the thing an agent pastes — same discipline as
# tests/pr-existence-guard/test.sh (#214), which this suite is modeled on.
set -euo pipefail
cd "$(dirname "$0")/../.."

RECIPE="./skills/implement-issue/references/github-mechanics.md"
[ -r "$RECIPE" ] || { echo "FAIL: $RECIPE missing — nothing to extract the guards from"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
FIXTURES="$KIT_ROOT/tests/plan-locate-comment-guard/fixtures"

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and both"
  echo "      guards this suite exercises are written in it."
  exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

# ----------------------------------------------------------------- 1. extract the shipped programs
#
# The markers are jq comments, so they can sit inside each program without changing it, and the
# recipe stays a single pasteable block. Every mark is matched as a fixed string, exactly once.
extract() {
  local begin="$1" end="$2" out="$3"
  local n_begin n_end
  n_begin=$(grep -c -F -- "$begin" "$RECIPE" || true)
  n_end=$(grep -c -F -- "$end" "$RECIPE" || true)
  if [ "$n_begin" != "1" ] || [ "$n_end" != "1" ]; then
    echo "FAIL: $RECIPE must carry EXACTLY ONE marked '$begin' guard program"
    echo "      found $n_begin begin and $n_end end marks"
    echo "      Two blocks means two homes for the guard, and a guard with two homes drifts."
    exit 1
  fi
  awk -v b="$begin" -v e="$end" '
    index($0, b) { inside = 1 }
    inside       { print }
    inside && index($0, e) { exit }
  ' "$RECIPE" > "$out"
  [ -s "$out" ] || { echo "FAIL: extracted an empty program for '$begin' from $RECIPE"; exit 1; }
}

MARKER_PROG="$WORK/marker-comment.jq"
CHECKBOX_PROG="$WORK/checkbox-fallback.jq"
extract '# >>> plan-locate marker-comment guard' '# <<< plan-locate marker-comment guard' "$MARKER_PROG"
extract '# >>> plan-locate checkbox-fallback guard' '# <<< plan-locate checkbox-fallback guard' "$CHECKBOX_PROG"

for prog in "$MARKER_PROG" "$CHECKBOX_PROG"; do
  if ! jq -f "$prog" < /dev/null > /dev/null 2>"$WORK/parse.err"; then
    echo "FAIL: the extracted guard program $prog does not compile:"
    sed 's/^/      /' "$WORK/parse.err"
    exit 1
  fi
done

# ---------------------------------------------------------------------------------- 2. the verdicts
#
# verdict <prog> <fixture> <want-id> <what it pins>
# want-id: the numeric comment id the guard should return; "" (empty string) means no match — the
# shipped `// empty` guard turns jq's own zero-match `null` into no output at all, which is what
# `$(...)` must capture for `[ -z "$PLAN_COMMENT_ID" ]` downstream to see (#286). No comment id is
# ever literally the string "null" or the empty string.
verdict() {
  local prog="$1" fixture="$2" want="$3" what="$4"
  local path="$FIXTURES/$fixture" got
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  if ! got=$(jq -r -f "$prog" < "$path" 2>"$WORK/run.err"); then
    note_fail "$fixture — the guard program errored ($what):
$(sed 's/^/      /' "$WORK/run.err")"
    return 0
  fi
  if [ "$got" != "$want" ]; then
    note_fail "$fixture — $what
      want: $want
      got:  $got"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# A null-body comment sitting next to a genuine marker comment must not crash the scan, and the
# real marker comment must still be found (#278, same shape as #259's null-body.json case).
verdict "$MARKER_PROG" null-body-with-marker.json 101 \
  'a null-body comment does not crash the marker-comment guard and the real marker still matches'
verdict "$CHECKBOX_PROG" null-body-with-marker.json 101 \
  'the checkbox-fallback guard also survives the same null-body neighbor (the marker comment carries checkbox lines too)'

# An array with ONLY a null-body comment — no marker, no checkboxes — must fall through cleanly to
# "no match" on both guards, not crash either one, and "no match" must be genuinely empty output
# (#286) — not the string "null", which `[ -z … ]` would treat as non-empty.
verdict "$MARKER_PROG" null-body-only.json "" \
  'a null-body-only comment set does not crash the marker-comment guard and yields a genuinely empty match'
verdict "$CHECKBOX_PROG" null-body-only.json "" \
  'a null-body-only comment set does not crash the checkbox-fallback guard and yields a genuinely empty match'

# An ordinary comment set that matches NEITHER filter — no null body anywhere, just no marker and no
# checkbox lines — is the everyday "fall through to the checkbox scan" / "stop, no plan" case this
# code exists to handle. It must also yield genuinely empty output, not the string "null" (#286).
verdict "$MARKER_PROG" zero-match.json "" \
  'an ordinary non-matching comment set yields a genuinely empty match from the marker-comment guard'
verdict "$CHECKBOX_PROG" zero-match.json "" \
  'an ordinary non-matching comment set yields a genuinely empty match from the checkbox-fallback guard'

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "plan-locate-comment-guard: FAILED"
  exit 1
fi
echo
echo "plan-locate-comment-guard: OK — both shipped guard programs survive a null comment body and"
echo "report a genuinely empty match, not the string \"null\", on any zero-match comment set."
