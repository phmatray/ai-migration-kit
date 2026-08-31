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
#   parser-missing  repo-local manifest declares a valid effort: axis, but
#                   skills/setup-repo/scripts/parse-manifest.py itself does not exist relative to
#                   the running survey.sh — the parser is never invoked at all (#239), a THIRD
#                   case #230's PARSER_RC path does not cover: "ran and declared nothing" and
#                   "ran and died" both differ from "never ran"
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
# A tracking PARENT of a decomposed job (#315, skills/create-issue/references/tracking-issue.md):
# the map body — Destination / Notes / Decisions so far / Not yet ticketed / Out of scope — and,
# by construction, none of the three tokens haveplan reads ("Implementation plan", "### Task",
# "- [ ]"). Its children carry the plans; the parent is the one issue that must NEVER be handed
# to a worker, and this body shape is the whole mechanism that keeps it out.
PARENT_BODY='## Problem\n\nthe whole job\n\n## Destination\n\nwhat done looks like\n\n## Notes\n\ninvariants every child obeys\n\n## Decisions so far\n\n- none yet\n\n## Not yet ticketed\n\nnone\n\n## Out of scope\n\n- nothing adjacent'

# $1 output path, remaining args "number|title|effort-or-empty|plan(0/1/parent)" quads
mkissues() {
  local out="$1"; shift
  {
    printf '['
    local first=1 rec num title eff plan body labels
    for rec in "$@"; do
      IFS='|' read -r num title eff plan <<<"$rec"
      [ "$first" = 1 ] || printf ','
      first=0
      case "$plan" in
        1)      body="$PLAN_BODY" ;;
        parent) body="$PARENT_BODY" ;;
        *)      body="$NO_PLAN_BODY" ;;
      esac
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

# $1 output file, $2 expected count, $3 expected third column ("-" or "waiting for a seed: #a #b")
#
# Asserts the RENDERED row, not the jq expression that produces it: the supervisor reads this line
# off stdout, so the contract is the two tab-separated fields, and a test that re-derived them from
# the same jq program could never disagree with a bug in it (the tautological anti-pattern in
# skills/_shared/test-seams.md).
assert_seed_row() {
  local out="$1" want_count="$2" want_tail="$3" line n got_count got_tail
  n=$(grep -c '^SEED' "$out" || true)
  if [ "$n" -ne 1 ]; then
    echo "FAIL: expected exactly 1 SEED row, found $n"; echo "---"; cat "$out"; exit 1
  fi
  line=$(grep '^SEED' "$out")
  # LAST row, always: it is a summary of the rows above it, and one printed mid-list is one the
  # supervisor — which reads the tail — will not find. It is also what keeps this addition
  # conflict-free against the other in-flight survey.sh changes.
  if [ "$(tail -n 1 "$out")" != "$line" ]; then
    echo "FAIL: the SEED row is not the last line of the output"; echo "---"; cat "$out"; exit 1
  fi
  got_count=$(printf '%s' "$line" | cut -f2)
  got_tail=$(printf '%s' "$line" | cut -f3)
  if [ "$got_count" != "$want_count" ] || [ "$got_tail" != "$want_tail" ]; then
    echo "FAIL: SEED row mismatch"
    echo "  want: count=$want_count tail=$want_tail"
    echo "  got : count=$got_count tail=$got_tail"
    exit 1
  fi
}

run_survey() {
  # $1 = CWD the case runs from (controls whether .github/repo-setup.yml resolves), $2 = fixture,
  # $3 = stdout capture path, $4 = optional survey.sh path (defaults to the real $SURVEY — case 6
  # passes a scratch copy so KIT_ROOT resolves against a tree missing parse-manifest.py). Absolute
  # so KIT_ROOT resolution inside it is unaffected by the cd — that resolution is exactly what
  # repo-profile.sh and repo-setup.sh both rely on too.
  local cwd="$1" fixture="$2" out="$3" script="${4:-$SURVEY}" rc=0
  ( cd "$cwd" && env PATH="$WORK/bin:$PATH" GH_ISSUES_FIXTURE="$fixture" bash "$script" ) > "$out" 2>"$out.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: survey.sh exited $rc"; cat "$out.err"; exit 1
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

# The unplanned tail #312 exists to surface: #105 is the fixture's only plan-less, non-QA issue.
assert_seed_row "$O1" 1 "waiting for a seed: #105"
echo "ok: word-vocab — the SEED summary row names the one issue waiting for a seed"

# --------------------------------------------------------- 1b. tracking-parent is never dispatched
#
# Witness for an invariant that already holds (#315): a decomposed job's PARENT carries no plan
# token, so `haveplan` is false and the parent lands in SKIP — even at a dispatchable tier. The
# medium-labelled parent is the load-bearing row: a large one is held by the tier check anyway,
# so only the medium one proves the BODY alone keeps a parent out of QUEUE. survey.sh is not
# changed by #315; this case exists so #317 (survey reads the edges and dispatches only the
# frontier) cannot loosen the jq without this row going red. The parent's child is an ordinary
# planned issue and queues as before.
#
# Not asserted here: the SEED row. A plan-less parent reads as "waiting for a seed" to today's
# survey (plan=false, not manual-QA), which is wrong for a tracking parent — the parent is
# plan-less on purpose. create-issue's `--seed` refuses a body with a `## Destination` heading;
# teaching the survey the shape is #317's, folded there rather than pinned here as if intended.

F1b="$WORK/tracking-parent-issues.json"
mkissues "$F1b" \
  "107|Tracking parent labelled medium|medium|parent" \
  "108|Tracking parent labelled large|large|parent" \
  "109|Child slice with its own plan|small|1"
O1b="$WORK/tracking-parent.out"
run_survey "$W1" "$F1b" "$O1b"

assert_bucket SKIP  107 "$O1b"
assert_bucket HOLD  108 "$O1b"
assert_bucket QUEUE 109 "$O1b"
if grep -F "$(printf '\t#107\t')" "$O1b" | grep -q 'plan=false'; then
  echo "ok: tracking-parent — a Destination/Notes/Decisions body reads plan=false and is SKIP at a dispatchable tier; its planned child queues"
else
  echo "FAIL: the tracking parent's row does not read plan=false"; cat "$O1b"; exit 1
fi

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

# ------------------------------------------------------------- 5. parser-failure (#230, not #213)
#
# The manifest's effort: axis is fine (xs/m, a vocabulary parse-manifest.py would read without
# complaint) but an UNRELATED label — this repo's own "type: bug" — carries a description over
# GitHub's 100-character cap, so parse-manifest.py's Task-2 validation (#200) dies before ever
# emitting a single "L" record. survey.sh's manifest-read pipeline redirects the parser's stderr
# to /dev/null, so this collapsed into the exact same empty VOCAB_JSON as "no effort: labels
# found" or "no readable manifest" — reopening #213's failure through a path #213 never
# exercised. The fix must still fall back to small/medium/large (the parser's real vocabulary is
# unconfirmed), but the stderr message must name the parser's actual error, not claim no axis was
# declared.

W5="$WORK/parser-failure"
mkdir -p "$W5/.github"
cat > "$W5/.github/repo-setup.yml" <<'YML'
labels:
  - name: "type: bug"
    color: "d73a4a"
    description: "This description is deliberately far longer than the one hundred character cap GitHub enforces on every label description field, so it trips the check."
  - name: "effort: xs"
    color: "c5def5"
    description: "extra-small"
  - name: "effort: m"
    color: "c5def5"
    description: "medium"
YML
F5="$WORK/parser-failure-issues.json"
mkissues "$F5" \
  "501|Small task, unrelated label trips the parser|xs|1" \
  "502|Medium task, unrelated label trips the parser|m|1"
O5="$WORK/parser-failure.out"
run_survey "$W5" "$F5" "$O5"

# The vocabulary could not be confirmed, so both fall back to the hardcoded small/medium/large
# ranking — neither "xs" nor "m" is in it, so both land past tier 2 (HOLD), same as
# degraded-fallback's unclassified case. That outcome is unchanged by this fix; what must change
# is the diagnostic naming why.
assert_bucket HOLD 501 "$O5"
assert_bucket HOLD 502 "$O5"

if ! grep -q "ERR: label 'type: bug'" "$O5.err"; then
  echo "FAIL: survey.sh stderr does not name the parser's real error"
  echo "---"
  cat "$O5.err"
  exit 1
fi
if grep -q "no effort: labels found" "$O5.err"; then
  echo "FAIL: survey.sh stderr still claims no effort axis was declared, masking the real parser failure"
  echo "---"
  cat "$O5.err"
  exit 1
fi
echo "ok: parser-failure — a parser death on an UNRELATED label is named, not folded into \"no effort axis\""

# ------------------------------------------------------------- 6. parser-missing (#239, not #230)
#
# The manifest declares a genuinely valid effort: axis, but parse-manifest.py itself does not
# exist — `[ -n "$MANIFEST" ] && [ -r "$PARSER" ]` is false, so the whole parser-invocation block
# (including PARSER_RC) is skipped entirely. survey.sh's KIT_ROOT is resolved relative to its OWN
# path (dirname "$0"), not the caller's CWD, so simulating "the parser file is missing" means
# running a COPY of survey.sh from a scratch tree that never had
# skills/setup-repo/scripts/parse-manifest.py in the first place — not chmod'ing the real kit's
# copy, and not merely removing execute permission (python3 reads the file as an argument, so
# `-r` — the check survey.sh actually makes — stays true after a bare `chmod -x`).

W6="$WORK/parser-missing"
mkdir -p "$W6/.github"
cat > "$W6/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML

SCRATCH_KIT="$WORK/scratch-kit-parser-missing"
mkdir -p "$SCRATCH_KIT/skills/auto-dev/scripts"
# A symlink, not a copy: survey.sh resolves KIT_ROOT from `dirname "$0"`, which operates on the
# path bash was invoked with, not the symlink's target — so this resolves KIT_ROOT to
# $SCRATCH_KIT exactly like a real copy would, without a byte-for-byte snapshot of survey.sh's
# own source that could silently drift from the file this suite is actually testing.
ln -s "$SURVEY" "$SCRATCH_KIT/skills/auto-dev/scripts/survey.sh"
# Deliberately no skills/setup-repo/scripts/parse-manifest.py anywhere under $SCRATCH_KIT.

F6="$WORK/parser-missing-issues.json"
mkissues "$F6" \
  "601|Small task, parser missing|small|1" \
  "602|Large task, parser missing|large|1"
O6="$WORK/parser-missing.out"

run_survey "$W6" "$F6" "$O6" "$SCRATCH_KIT/skills/auto-dev/scripts/survey.sh"

# The vocabulary could not be confirmed (the parser never ran), so both fall back to the hardcoded
# small/medium/large ranking — same ranking outcome as degraded-fallback. What must differ is the
# stderr wording: it must name the parser as missing/unreadable, not claim the manifest declared
# no effort: axis (which would be false — it declares one correctly).
assert_bucket QUEUE 601 "$O6"
assert_bucket HOLD  602 "$O6"

if ! grep -qi "parser.*missing or unreadable" "$O6.err"; then
  echo "FAIL: survey.sh stderr does not name the parser as missing/unreadable"
  echo "---"
  cat "$O6.err"
  exit 1
fi
if grep -q "no effort: labels found" "$O6.err"; then
  echo "FAIL: survey.sh stderr still claims no effort axis was declared, masking the missing parser"
  echo "---"
  cat "$O6.err"
  exit 1
fi
echo "ok: parser-missing — a parser that never ran is named distinctly, not folded into \"no effort axis\""

# -------------------------------------------------------------- 7. pipeline-failure (#251, not any of the above)
#
# The manifest declares a genuinely valid effort: axis and parse-manifest.py reads it without
# complaint (PARSER_RC=0, PARSER_ATTEMPTED=1) — but the awk|grep|sed|tr|jq pipeline that turns the
# parser's stdout into VOCAB_JSON breaks downstream of the parser, because one of ITS tools is
# broken, not because the manifest declares nothing. Shadow jq on PATH with a stub that always
# exits nonzero, leaving python3/awk/grep/sed/tr untouched so the parser itself keeps succeeding —
# same shape as the issue's own reproduction. Today's code has no way to see this: it folds the
# resulting empty VOCAB_JSON into the same "no effort: labels found" message #213/#230/#239 already
# had to disambiguate from two OTHER causes, wrongly telling an operator the manifest is the
# problem when the manifest and the parser are both fine.

W7="$WORK/pipeline-failure"
mkdir -p "$W7/.github" "$W7/bin"
cat > "$W7/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML

# A stub jq that fails ONLY the vocabulary-extraction invocation (`jq -R -s '...'`), ahead of the
# real one on PATH. survey.sh's OWN final step also calls jq (`gh issue list | jq -r --argjson
# vocab ... '...'`, no `-R`) to bucket the issues — that call is unrelated to the bug under test,
# so the stub execs the real binary for it instead of failing the whole script for the wrong
# reason. parse-manifest.py itself does not shell out to jq at all, so the parser is untouched.
REAL_JQ="$(command -v jq)"
[ -n "$REAL_JQ" ] || { echo "FAIL: no system jq found to build the pipeline-failure stub"; exit 1; }
cat > "$W7/bin/jq" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "-R" ]; then
  exit 1
fi
exec "$REAL_JQ" "\$@"
STUB
chmod +x "$W7/bin/jq"

F7="$WORK/pipeline-failure-issues.json"
mkissues "$F7" \
  "701|Small task, vocabulary pipeline broken|small|1" \
  "702|Large task, vocabulary pipeline broken|large|1"
O7="$WORK/pipeline-failure.out"

# run_survey's own PATH="$WORK/bin:$PATH" comes first for the `gh` stub; prepend $W7/bin here too
# so the broken jq shadows the real one without disturbing that gh lookup.
( cd "$W7" && env PATH="$W7/bin:$WORK/bin:$PATH" GH_ISSUES_FIXTURE="$F7" bash "$SURVEY" ) \
  > "$O7" 2>"$O7.err" || { echo "FAIL: survey.sh exited $? on pipeline-failure"; cat "$O7.err"; exit 1; }

# The vocabulary could not be confirmed, so both fall back to the hardcoded small/medium/large
# ranking — same ranking outcome as every other fallback case above. What must differ is the
# stderr wording: it must name the pipeline as the failure point, not claim the manifest declared
# no effort: axis (which would be false — it declares one correctly, and the parser read it fine).
assert_bucket QUEUE 701 "$O7"
assert_bucket HOLD  702 "$O7"

if ! grep -qi "vocabulary-extraction pipeline.*failed" "$O7.err"; then
  echo "FAIL: survey.sh stderr does not name the vocabulary pipeline as the failure point"
  echo "---"
  cat "$O7.err"
  exit 1
fi
if grep -q "no effort: labels found" "$O7.err"; then
  echo "FAIL: survey.sh stderr still claims no effort axis was declared, masking the broken pipeline"
  echo "---"
  cat "$O7.err"
  exit 1
fi
echo "ok: pipeline-failure — a broken downstream tool after a successful parser run is named distinctly, not folded into \"no effort axis\""

# --------------------------------------------------- 7b. degraded-fallback keeps its own wording
#
# Guards the boundary this fix must not cross: grep -i '^effort:' finding no match (because the
# manifest genuinely declares no effort: axis) is NOT a pipeline failure and must still produce the
# pre-existing "no effort: labels found" message, not the new one.
if ! grep -q "no effort: labels found" "$O4.err"; then
  echo "FAIL: degraded-fallback's stderr no longer says \"no effort: labels found\" — the new pipeline-failure branch may be over-firing on grep's expected no-match exit"
  echo "---"
  cat "$O4.err"
  exit 1
fi
if grep -qi "vocabulary-extraction pipeline" "$O4.err"; then
  echo "FAIL: degraded-fallback's stderr wrongly claims the pipeline failed — grep's expected no-match exit must not trip the new branch"
  echo "---"
  cat "$O4.err"
  exit 1
fi
echo "ok: degraded-fallback (recheck) — grep's expected no-match exit still reads as \"no effort axis declared\", not a pipeline failure"

# ---------------------------------------------- 8. pipeline-partial-failure (mid-stream, not empty)
#
# Case 7's stub jq fails BEFORE writing anything, so VOCAB_JSON ends up empty and the existing
# `[ -z "$VOCAB_JSON" ]` gate already catches it regardless of VOCAB_PIPE_FAILED. This case is
# different and harder: `sed` dies mid-stream (a transient kill/I-O error, exit 2) AFTER already
# forwarding its first matched line downstream, so jq still slurps that partial input and emits a
# perfectly well-formed, NON-empty, NON-"[]" array — just missing "medium" and "large". Without
# ORing VOCAB_PIPE_FAILED into the outer fallback gate, this truncated vocabulary would silently
# pass through as if it were the real one: no stderr warning, and every "medium"/"large" issue
# would rank past tier 2 (HOLD) instead of falling back to small/medium/large, where they QUEUE.
W8="$WORK/pipeline-partial-failure"
mkdir -p "$W8/.github" "$W8/bin"
cat > "$W8/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML

REAL_SED="$(command -v sed)"
[ -n "$REAL_SED" ] || { echo "FAIL: no system sed found to build the pipeline-partial-failure stub"; exit 1; }
# Forwards exactly the first input line through the real transform, then dies — reproducing a
# tool that flushed partial output before breaking, not one that never produced any.
cat > "$W8/bin/sed" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"[Ee][Ff][Ff][Oo][Rr][Tt]"* ]]; then
  IFS= read -r first_line
  printf '%s\n' "\$first_line" | "$REAL_SED" -E 's/^[Ee][Ff][Ff][Oo][Rr][Tt]:[[:space:]]*//'
  exit 2
fi
exec "$REAL_SED" "\$@"
STUB
chmod +x "$W8/bin/sed"

F8="$WORK/pipeline-partial-failure-issues.json"
mkissues "$F8" \
  "801|Small task, pipeline partially failed|small|1" \
  "802|Medium task, pipeline partially failed|medium|1" \
  "803|Large task, pipeline partially failed|large|1"
O8="$WORK/pipeline-partial-failure.out"

( cd "$W8" && env PATH="$W8/bin:$WORK/bin:$PATH" GH_ISSUES_FIXTURE="$F8" bash "$SURVEY" ) \
  > "$O8" 2>"$O8.err" || { echo "FAIL: survey.sh exited $? on pipeline-partial-failure"; cat "$O8.err"; exit 1; }

# The vocabulary could not be confirmed (it was truncated to just ["small"], not the manifest's
# real small/medium/large), so all three fall back to the hardcoded ranking, same as every other
# fallback case — NOT the corrupted tiering a truncated vocab would otherwise silently produce
# (which would HOLD the medium-labeled issue because "medium" fell outside the truncated array).
assert_bucket QUEUE 801 "$O8"
assert_bucket QUEUE 802 "$O8"
assert_bucket HOLD  803 "$O8"

if ! grep -qi "vocabulary-extraction pipeline.*failed" "$O8.err"; then
  echo "FAIL: survey.sh stderr does not name the vocabulary pipeline as the failure point for a mid-stream partial failure"
  echo "---"
  cat "$O8.err"
  exit 1
fi
if grep -q "no effort: labels found" "$O8.err"; then
  echo "FAIL: survey.sh stderr claims no effort axis was declared, masking a mid-stream pipeline failure that left truncated-but-valid output"
  echo "---"
  cat "$O8.err"
  exit 1
fi
echo "ok: pipeline-partial-failure — a pipe stage that dies AFTER flushing partial output doesn't silently pass its truncated vocabulary through"

# ------------------------------------------------------- 9. vocab-tmp-mktemp-failure (infra, not manifest)
#
# The manifest declares a genuinely valid effort: axis and parse-manifest.py reads it without
# complaint — but the SECOND mktemp call (for $VOCAB_TMP, the file the extraction pipeline's stdout
# is routed through) fails outright, so the pipeline body never even runs. Before this fix,
# VOCAB_PIPE_FAILED stayed at its default 0 in this case and the diagnosis fell through to "no
# effort: labels found", blaming the manifest for an infra failure. Shadow `mktemp` on PATH with a
# stub that always fails; python3/awk/grep/sed/tr/jq are untouched, so the parser itself keeps
# succeeding. (This also starves PARSER_ERR_FILE's own mktemp a few lines earlier — a real,
# previously-untested path of its own — but that only changes PARSER_STDERR's sentinel text, not
# PARSER_RC, so it does not interfere with this case's assertions.)
W9="$WORK/vocab-tmp-mktemp-failure"
mkdir -p "$W9/.github" "$W9/bin"
cat > "$W9/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML
cat > "$W9/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$W9/bin/mktemp"

F9="$WORK/vocab-tmp-mktemp-failure-issues.json"
mkissues "$F9" \
  "901|Small task, VOCAB_TMP mktemp fails|small|1" \
  "902|Large task, VOCAB_TMP mktemp fails|large|1"
O9="$WORK/vocab-tmp-mktemp-failure.out"

# $W9/bin comes first so the stub mktemp shadows the real one; run_survey's helper can't be reused
# unmodified since it doesn't let a case prepend its own bin dir ahead of $WORK/bin.
( cd "$W9" && env PATH="$W9/bin:$WORK/bin:$PATH" GH_ISSUES_FIXTURE="$F9" bash "$SURVEY" ) \
  > "$O9" 2>"$O9.err" || { echo "FAIL: survey.sh exited $? on vocab-tmp-mktemp-failure"; cat "$O9.err"; exit 1; }

# The vocabulary could not be confirmed, so both fall back to the hardcoded small/medium/large
# ranking — same ranking outcome as every other fallback case. What must differ is the stderr
# wording: it must not claim the manifest declared no effort: axis (it does, correctly).
assert_bucket QUEUE 901 "$O9"
assert_bucket HOLD  902 "$O9"

if ! grep -qi "vocabulary-extraction pipeline.*failed" "$O9.err"; then
  echo "FAIL: survey.sh stderr does not name the vocabulary pipeline as the failure point when VOCAB_TMP's mktemp fails"
  echo "---"
  cat "$O9.err"
  exit 1
fi
if grep -q "no effort: labels found" "$O9.err"; then
  echo "FAIL: survey.sh stderr claims no effort axis was declared, masking a mktemp failure unrelated to the manifest"
  echo "---"
  cat "$O9.err"
  exit 1
fi
echo "ok: vocab-tmp-mktemp-failure — a failure to even create the pipeline's temp file is named distinctly, not folded into \"no effort axis\""

# --------------------------------------------- 10. vocab-tmp-readback-failure (pipe ok, cat fails)
#
# The extraction pipeline itself runs cleanly (every stage would exit 0), but reading its output
# back via `cat -- "$VOCAB_TMP"` fails — a permissions race or I/O hiccup on the temp file between
# the write and the read. VOCAB_PIPE_FAILED would stay 0 from the per-stage loop alone (the pipe
# genuinely succeeded), so this exercises the OTHER half of the fix: the `cat` failure itself must
# also set VOCAB_PIPE_FAILED, or this collapses into "no effort: labels found" exactly like the
# other two infra-failure cases above. Shadow `cat` on PATH with a stub that fails only for the
# `cat -- <file>` invocation shape survey.sh actually uses, execing the real binary otherwise (the
# gh stub and mkissues/assert_bucket in this suite don't call `cat --`, so nothing else breaks).
W10="$WORK/vocab-tmp-readback-failure"
mkdir -p "$W10/.github" "$W10/bin"
cat > "$W10/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML
REAL_CAT="$(command -v cat)"
[ -n "$REAL_CAT" ] || { echo "FAIL: no system cat found to build the vocab-tmp-readback-failure stub"; exit 1; }
cat > "$W10/bin/cat" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--" ]; then
  exit 1
fi
exec "$REAL_CAT" "\$@"
STUB
chmod +x "$W10/bin/cat"

F10="$WORK/vocab-tmp-readback-failure-issues.json"
mkissues "$F10" \
  "1001|Small task, VOCAB_TMP readback fails|small|1" \
  "1002|Large task, VOCAB_TMP readback fails|large|1"
O10="$WORK/vocab-tmp-readback-failure.out"

( cd "$W10" && env PATH="$W10/bin:$WORK/bin:$PATH" GH_ISSUES_FIXTURE="$F10" bash "$SURVEY" ) \
  > "$O10" 2>"$O10.err" || { echo "FAIL: survey.sh exited $? on vocab-tmp-readback-failure"; cat "$O10.err"; exit 1; }

assert_bucket QUEUE 1001 "$O10"
assert_bucket HOLD  1002 "$O10"

if ! grep -qi "vocabulary-extraction pipeline.*failed" "$O10.err"; then
  echo "FAIL: survey.sh stderr does not name the vocabulary pipeline as the failure point when reading VOCAB_TMP back fails"
  echo "---"
  cat "$O10.err"
  exit 1
fi
if grep -q "no effort: labels found" "$O10.err"; then
  echo "FAIL: survey.sh stderr claims no effort axis was declared, masking a readback failure after a successful pipeline"
  echo "---"
  cat "$O10.err"
  exit 1
fi
echo "ok: vocab-tmp-readback-failure — a successful pipeline whose output can't be read back is named distinctly, not folded into \"no effort axis\""

# --------------------------------------------- 11. the SEED summary row (#312): what still needs a plan
#
# The row exists because an unplanned backlog and a drained one look identical in the QUEUE/HOLD/SKIP
# rows alone — the supervisor sees a short queue and reports an empty one. Two facts about the count
# that the bucket assertions above cannot pin:
#
#   * it is NOT "the SKIP rows without a plan". A raw issue filed from the GitHub UI carries no
#     effort: label either, so it tiers to 999 and lands in HOLD, not SKIP — counting only SKIP rows
#     would miss precisely the population `--seed` was added for. The count is every row with
#     plan=false, whichever bucket it fell into.
#   * manual-QA issues are excluded even when they have no plan: seeding one produces a plan no
#     headless worker may execute, so it is not "waiting for a seed" in any useful sense.

W11="$WORK/seed-row"
mkdir -p "$W11/.github"
cat > "$W11/.github/repo-setup.yml" <<'YML'
labels:
  - name: "effort: small"
  - name: "effort: medium"
  - name: "effort: large"
YML

# 11a — every issue has a plan: the row still prints, and says zero. A missing row and a zero row
# are different claims ("this survey doesn't report it" vs "nothing is waiting"), and the supervisor
# needs the second one.
F11A="$WORK/seed-row-all-planned.json"
mkissues "$F11A" \
  "1101|Planned small|small|1" \
  "1102|Planned medium|medium|1"
O11A="$WORK/seed-row-all-planned.out"
run_survey "$W11" "$F11A" "$O11A"
assert_bucket QUEUE 1101 "$O11A"
assert_bucket QUEUE 1102 "$O11A"
assert_seed_row "$O11A" 0 "-"
echo "ok: seed-row — a fully-planned backlog still prints the row, as SEED 0 -"

# 11b — the mixed case, one issue per rule.
F11B="$WORK/seed-row-mixed.json"
mkissues "$F11B" \
  "1201|Planned small|small|1" \
  "1202|Raw idea filed from the UI||0" \
  "1203|No plan yet|small|0" \
  "1204|Verify by hand before shipping|small|0"
O11B="$WORK/seed-row-mixed.out"
run_survey "$W11" "$F11B" "$O11B"
assert_bucket QUEUE 1201 "$O11B"
assert_bucket HOLD  1202 "$O11B"
assert_bucket SKIP  1203 "$O11B"
assert_bucket SKIP  1204 "$O11B"
# #1202 (HOLD, unlabelled) and #1203 (SKIP) wait for a seed; #1201 has one; #1204 is manual-QA.
# Listed by issue number, not by the tier order the rows above are sorted in.
assert_seed_row "$O11B" 2 "waiting for a seed: #1202 #1203"
echo "ok: seed-row — counts every plan-less issue including HOLD, and excludes manual-QA"
