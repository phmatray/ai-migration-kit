#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/survey.sh's effort tiering (#213).
#
# The bug: `tier` matched a bare uppercase S/M/L against the effort: label text. This repo's own
# labels are word-spelled ("effort: small"/"medium"/"large"), none of which contain an uppercase
# S/M/L, so every issue fell to tier 4 — the same bucket as an unclassified issue — and the
# survey printed all HOLD, zero QUEUE. SKILL.md's Step 2 treats an empty queue as "backlog
# drained", so the failure looked like success.
#
# The fix reads the ORDERED effort: vocabulary from a repo-setup.yml manifest (via the same
# skills/setup-repo/scripts/parse-manifest.py the setup skill already uses) and ranks each
# issue's effort label against that order, rather than assuming a spelling. Four cases below drive
# every branch of that logic:
#
#   word-vocab      repo-local manifest, this repo's own word-spelled labels — the reported bug
#   letter-vocab    repo-local manifest, S/M/L/XL — the spelling the ORIGINAL regex assumed,
#                   proving the fix does not regress the one case the old code handled
#   default-fallback  no repo-local manifest at all — falls through to the kit's shipped
#                   templates/repo-setup.yml, exercised for real (not simulated)
#   degraded-fallback  repo-local manifest present and parses, but declares no effort: axis —
#                   the hardcoded case-insensitive fallback must still classify correctly, not
#                   silently reproduce the all-HOLD bug this issue reports
#
# word-vocab also carries a no-plan and a manual-QA issue, so the SKIP branch (untouched by this
# fix) is proven still reachable and the bucket names stay QUEUE/HOLD/SKIP.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

SURVEY="$KIT/skills/auto-dev/scripts/survey.sh"
[ -x "$SURVEY" ] || { echo "FAIL: $SURVEY missing or not executable"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

# ------------------------------------------------------------------------------------ the gh stub
#
# survey.sh makes exactly one gh call: `gh issue list --state open --limit 300 --json ...`. The
# stub serves whatever fixture the case points it at, and — because real `gh issue list` applies
# a `--jq EXPRESSION` argument itself, raw-printing the result — the stub does too. That is not
# incidental: it is what lets this suite catch the ORIGINAL bug fairly. The pre-fix script filters
# inline via `gh issue list --jq '...'`; the fix moved that filter to a separate `jq` piped after a
# plain `gh issue list --json ...` call with no `--jq` at all. A stub that only ever `cat`s the
# fixture would silently skip the pre-fix script's filtering step entirely and could not fail
# against it — this one runs whichever shape the caller used.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  [ -n "${GH_ISSUES_FIXTURE:-}" ] || { echo "GH_ISSUES_FIXTURE not set" >&2; exit 1; }
  jq_expr=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--jq" ] || [ "$prev" = "-q" ]; then jq_expr="$a"; fi
    prev="$a"
  done
  if [ -n "$jq_expr" ]; then
    jq -r "$jq_expr" "$GH_ISSUES_FIXTURE"
  else
    cat "$GH_ISSUES_FIXTURE"
  fi
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"

# Literal two-character `\n` (not a real newline) — this is embedded directly into a JSON string
# literal below, and `\n` is JSON's own escape for a newline, so it decodes correctly on the jq
# side without bash ever needing to produce an actual newline. Plain "Implementation plan" text is
# enough to satisfy survey.sh's haveplan regex; no emoji needed.
PLAN_BODY='## context\n\n## Implementation plan\n- [ ] Step 1: do it'
NO_PLAN_BODY='## context only, nothing to execute'

# $1 output path, remaining args "number|title|effort-or-empty|plan(0/1)" quads
mkissues() {
  local out="$1"; shift
  {
    printf '['
    local first=1 rec num title eff plan body labels
    for rec in "$@"; do
      IFS='|' read -r num title eff plan <<<"$rec"
      [ "$first" = 1 ] || printf ','
      first=0
      if [ "$plan" = "1" ]; then body="$PLAN_BODY"; else body="$NO_PLAN_BODY"; fi
      if [ -n "$eff" ]; then labels="[{\"name\":\"effort: $eff\"}]"; else labels="[]"; fi
      printf '{"number":%s,"title":"%s","labels":%s,"body":"%s"}' "$num" "$title" "$labels" "$body"
    done
    printf ']'
  } > "$out"
}

# $1 bucket wanted, $2 issue number, $3 output file
assert_bucket() {
  local want="$1" num="$2" out="$3" line got
  line=$(grep -F "$(printf '\t#%s\t' "$num")" "$out" || true)
  [ -n "$line" ] || { echo "FAIL: issue #$num not found in output"; echo "---"; cat "$out"; exit 1; }
  got=$(printf '%s' "$line" | cut -f1 | sed 's/[[:space:]]*$//')
  if [ "$got" != "$want" ]; then
    echo "FAIL: issue #$num expected bucket $want, got $got"
    echo "$line"
    exit 1
  fi
}

run_survey() {
  # $1 = CWD the case runs from (controls whether .github/repo-setup.yml resolves), $2 = fixture,
  # $3 = stdout capture path. Absolute $SURVEY so KIT_ROOT resolution inside it is unaffected by
  # the cd — that resolution is exactly what repo-profile.sh and repo-setup.sh both rely on too.
  local rc=0
  ( cd "$1" && env PATH="$WORK/bin:$PATH" GH_ISSUES_FIXTURE="$2" bash "$SURVEY" ) > "$3" 2>"$3.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: survey.sh exited $rc"; cat "$3.err"; exit 1
  fi
}

# ------------------------------------------------------------------------ 1. word-vocab (the bug)

W1="$WORK/word-vocab"
mkdir -p "$W1/.github"
cat > "$W1/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML
F1="$WORK/word-vocab-issues.json"
mkissues "$F1" \
  "101|Small task|small|1" \
  "102|Medium task|medium|1" \
  "103|Large task|large|1" \
  "104|Unlabelled task||1" \
  "105|No plan yet|small|0" \
  "106|Needs manual QA by hand|small|1"
O1="$WORK/word-vocab.out"
run_survey "$W1" "$F1" "$O1"

assert_bucket QUEUE 101 "$O1"
assert_bucket QUEUE 102 "$O1"
assert_bucket HOLD  103 "$O1"
assert_bucket HOLD  104 "$O1"
assert_bucket SKIP  105 "$O1"
assert_bucket SKIP  106 "$O1"
echo "ok: word-vocab — this repo's own effort: small/medium/large labels tier and queue correctly"

# ------------------------------------------------------------------- 2. letter-vocab (no regress)

W2="$WORK/letter-vocab"
mkdir -p "$W2/.github"
cat > "$W2/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: S"
  - name: "effort: M"
  - name: "effort: L"
  - name: "effort: XL"
YML
F2="$WORK/letter-vocab-issues.json"
mkissues "$F2" \
  "201|Small letter task|S|1" \
  "202|Medium letter task|M|1" \
  "203|Large letter task|L|1" \
  "204|Extra-large letter task|XL|1"
O2="$WORK/letter-vocab.out"
run_survey "$W2" "$F2" "$O2"

assert_bucket QUEUE 201 "$O2"
assert_bucket QUEUE 202 "$O2"
assert_bucket HOLD  203 "$O2"
assert_bucket HOLD  204 "$O2"
echo "ok: letter-vocab — a manifest declaring S/M/L/XL still tiers correctly"

# --------------------------------------------------------- 3. default-fallback (kit shipped file)

W3="$WORK/default-fallback"
mkdir -p "$W3"
F3="$WORK/default-fallback-issues.json"
mkissues "$F3" \
  "301|Small default task|small|1" \
  "302|Medium default task|medium|1" \
  "303|Large default task|large|1"
O3="$WORK/default-fallback.out"
run_survey "$W3" "$F3" "$O3"

assert_bucket QUEUE 301 "$O3"
assert_bucket QUEUE 302 "$O3"
assert_bucket HOLD  303 "$O3"
echo "ok: default-fallback — no repo-local manifest falls through to the kit's shipped templates/repo-setup.yml"

# --------------------------------------------------- 4. degraded-fallback (manifest, no effort:)

W4="$WORK/degraded-fallback"
mkdir -p "$W4/.github"
cat > "$W4/.github/repo-setup.yml" <<'YML'
labels:
  - name: "bug"
  - name: "priority: high"
YML
F4="$WORK/degraded-fallback-issues.json"
mkissues "$F4" \
  "401|Small task, no effort axis declared|small|1" \
  "402|Large task, no effort axis declared|large|1"
O4="$WORK/degraded-fallback.out"
run_survey "$W4" "$F4" "$O4"

assert_bucket QUEUE 401 "$O4"
assert_bucket HOLD  402 "$O4"
echo "ok: degraded-fallback — a manifest with no effort: axis still classifies word-spelled labels, not all-HOLD"
