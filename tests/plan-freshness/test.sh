#!/usr/bin/env bash
# Golden test for skills/implement-issue/scripts/plan-freshness.sh and the SKILL.md prose that
# consumes it (#322).
#
# Why this exists. `implement-issue` Step 2 parses a plan that was written when the issue was
# FILED and executes it however long afterwards — #233 and #245 both trace to a `**Files:**` line
# naming a path that `main` no longer had. The failure shape is the one this repo keeps closing:
# nothing reports a problem. A subagent opens the file, finds it absent, improvises a nearby one,
# the task goes green, and Step 10 never says the plan was stale. `plan-freshness.sh` turns that
# silence into an exit code, and this suite drives both of its verdicts plus its refusal.
#
# The seam is the script's own CLI: argv in, stdout lines + exit code out, run against a scratch
# git repository built here (skills/_shared/test-seams.md — highest boundary a test can reach, and
# the one CI and Step 2 both actually depend on). Nothing is sourced; no internal is asserted on.
#
# Ported alongside the mechanisms in skills/implement-issue/references/spec-review.md from
# mattpocock/skills (MIT) — `engineering/code-review` and `in-progress/implement-spec`.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

SCRIPT="$KIT_ROOT/skills/implement-issue/scripts/plan-freshness.sh"
SKILL="$KIT_ROOT/skills/implement-issue/SKILL.md"
MECHANICS="$KIT_ROOT/skills/implement-issue/references/github-mechanics.md"
SPEC_REVIEW="$KIT_ROOT/skills/implement-issue/references/spec-review.md"
WORK=$(kit_scratch)

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }
note_ok()   { echo "ok   [$1]"; }

[ -x "$SCRIPT" ] || {
  echo "FAIL: $SCRIPT is missing or not executable — there is nothing to drive."
  echo "      Step 2 of implement-issue calls it by that path; a suite that skipped here would"
  echo "      report green about a script CI would fail on."
  exit 1; }

# ------------------------------------------------------------------ 1. the scratch repository
#
# A real repository, not a fixture directory: the script's whole job is `git cat-file -e <ref>:<p>`,
# so a stub of git would move the seam from "does this resolve against a ref" to "does this call
# the function I named git" — the mocking anti-pattern in _shared/test-seams.md.
REPO="$WORK/repo"
mkdir -p "$REPO/dir with space"
git -C "$REPO" init -q
git -C "$REPO" config user.email "suite@example.invalid"
git -C "$REPO" config user.name "plan-freshness suite"
printf 'x\n' > "$REPO/a.sh"
printf 'y\n' > "$REPO/dir with space/b.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"

# `origin/main` without a remote: the script's default base is a ref name, and a remote-tracking
# ref is just a ref. This keeps the default path under test without a network or a second clone.
git -C "$REPO" update-ref refs/remotes/origin/main HEAD

# A second ref where a.sh does NOT exist, so `--base` is proved to be READ rather than accepted and
# ignored — a flag that is parsed and discarded passes every test that only ever spells the default.
git -C "$REPO" checkout -q -b without-a
git -C "$REPO" rm -q "a.sh"
git -C "$REPO" commit -qm "drop a.sh"
git -C "$REPO" checkout -q -

# ------------------------------------------------------------------------------- 2. the fixtures
cat > "$WORK/mixed.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the mixed case

**Files:** modify `a.sh`, `gone.sh`; create `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN

cat > "$WORK/all-present.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: everything still there

**Files:** modify `a.sh`; modify `dir with space/b.sh`.

- [ ] **Step 1:** do the thing.
PLAN

cat > "$WORK/no-tasks.md" <<'PLAN'
## Problem

There is no plan here at all — no `### Task` heading anywhere in the file.

**Files:** modify `a.sh`.
PLAN

# ------------------------------------------------------------------------------- 3. the verdicts
#
# run_case <label> <want-exit> <plan> [extra args…]
# stdout goes to a file; the assertions read that file. Nothing is piped through head/tail — the
# whole output is the evidence, and a truncated capture is how a wrong line goes unnoticed.
OUT="$WORK/out.txt"
run_case() {
  local label="$1" want="$2" plan="$3"; shift 3
  local got=0
  "$SCRIPT" -C "$REPO" "$@" "$plan" > "$OUT" 2>&1 || got=$?
  if [ "$got" != "$want" ]; then
    note_fail "$label — exit $got, wanted $want"
    sed 's/^/      /' "$OUT"
    return 0
  fi
  note_ok "$label"
}

want_line() {
  local label="$1" line="$2"
  if grep -Fxq "$line" "$OUT"; then
    note_ok "$label"
  else
    note_fail "$label — no line '$line' in the output:"
    sed 's/^/      /' "$OUT"
  fi
}

echo "== a plan with a stale modify path is exit 5, and says which path (#322) =="
run_case "C1 mixed plan exits 5             " 5 "$WORK/mixed.md"
want_line "C2 the present path is OK         " "OK modify a.sh (Task 1)"
want_line "C3 the absent path is MISSING     " "MISSING modify gone.sh (Task 1)"
want_line "C4 a create path is SKIPped       " "SKIP create new.sh (Task 1)"

echo "== a plan whose every path still exists is exit 0 =="
run_case "C5 all-present plan exits 0        " 0 "$WORK/all-present.md"
want_line "C6 a path with a space survives   " "OK modify dir with space/b.sh (Task 1)"

echo "== a file with no ### Task is a usage refusal (exit 2), not a silent pass =="
run_case "C7 task-less plan exits 2          " 2 "$WORK/no-tasks.md"

echo "== --base is READ, not merely accepted =="
run_case "C8 --base without-a finds a.sh gone" 5 "$WORK/all-present.md" --base without-a
want_line "C9 …and names it MISSING          " "MISSING modify a.sh (Task 1)"
run_case "C10 --base origin/main is the same as the default" 0 "$WORK/all-present.md" --base origin/main

# --------------------------------------------------- 4. the prose that has to CALL the script
#
# A shipped script nothing invokes is the same absence-shaped failure ci-wiring-check.py exists for,
# one layer up: `plan-freshness.sh` can be green on every case above while SKILL.md Step 2 never
# mentions it, and a run would then execute a stale plan exactly as it did before #322. So the
# call site is pinned too — per STEP, not per file, because a grep over the whole SKILL.md passes
# on a mention parked in any other step.

section() {  # section <file> <start-heading> <end-heading> -> path to the extracted block
  # One file PER extraction. A single shared $WORK/section.txt made every $STEPn variable hold the
  # same path, so the five blocks were only ever correct because the calls and their assertions
  # happened to interleave in order — reorder one and it silently checks a different step's text.
  local file="$1" start="$2" end="$3" out
  out="$WORK/section-$(printf '%s' "$start" | tr -c 'A-Za-z0-9' '-').txt"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { inside = 1 }
    inside && index($0, e) == 1 && index($0, s) != 1 { exit }
    inside { print }
  ' "$file" > "$out"
  printf '%s' "$out"
}

want_in() {  # want_in <label> <file> <needle>
  local label="$1" file="$2" needle="$3"
  if [ -s "$file" ] && grep -Fq -- "$needle" "$file"; then
    note_ok "$label"
  else
    note_fail "$label — '$needle' is not in $(basename "$file")"
  fi
}

[ -r "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }

echo "== a parenthetical aside is an ASIDE, not two paths (found in review of #322) =="
#
# `create-issue`'s own template writes `modify `Program.cs` (DI registration)`. Splitting on ", "
# before the aside came out turned ONE fresh path into two invented ones, both MISSING, exit 5 —
# and exit 5 is what routes Step 2 into re-anchoring, where an invented path anchors to nothing and
# becomes the "no usable plan" stop. A false stale costs the whole run, so it is pinned here.
cat > "$WORK/aside.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: asides

**Files:** modify `a.sh` (the entry point, and its guard); modify `dir with space/b.sh` (one line).
PLAN
run_case "C11 a comma inside () is not a split" 0 "$WORK/aside.md"
want_line "C12 …and the path survives whole  " "OK modify a.sh (Task 1)"

echo "== a wrapped **Files:** line is JOINED before parsing, not two failures (#419) =="
#
# `create-issue`'s own template writes `**Files:**` as flowing prose meant to be soft-wrapped, and
# issue #412's own plan did exactly that — a parenthetical aside spanning the wrap point. Before
# this fix the read loop only ever looked at ONE physical line: the first line's unclosed `(`
# corrupted the comma-split into bogus fragments and reported a false `MISSING`, and the second
# physical line — which starts with neither `### Task` nor `**Files:**` — matched no case at all and
# vanished from the output with NO verdict, neither OK nor MISSING. Both failures are pinned here:
# a fixture that mirrors #412's real shape (paren spanning the wrap, verb + path continuing after
# it) whose every named path genuinely exists, so a correct join reads exit 0 with both paths OK.
cat > "$WORK/wrap-ok.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: wrap with only real paths

**Files:** modify `a.sh` (the entry point, and the
guard list); test `dir with space/b.sh` (new).

- [ ] **Step 1:** do the thing.
PLAN
run_case "C30 a wrapped Files line exits 0    " 0 "$WORK/wrap-ok.md"
want_line "C31 …the first line's path is OK   " "OK modify a.sh (Task 1)"
want_line "C32 …the WRAPPED path is OK too    " "OK test dir with space/b.sh (Task 1)"

echo "== …and a genuinely stale path AFTER the wrap is still caught, not lost (#419) =="
#
# The mirror image of C30-C32: the same wrapped shape, but the path named on the continuation line
# does not exist. If the continuation were still silently dropped (rather than merely mis-split),
# this would read as a false-fresh exit 0 instead of the exit 5 a real stale path demands.
cat > "$WORK/wrap-missing.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: wrap with a stale path after the wrap

**Files:** modify `a.sh` (the entry point, and the
guard list); test `gone.sh` (new).

- [ ] **Step 1:** do the thing.
PLAN
run_case "C33 a wrapped stale path exits 5    " 5 "$WORK/wrap-missing.md"
want_line "C34 …and the WRAPPED path is MISSING" "MISSING test gone.sh (Task 1)"

echo "== …and a field with NO blank line before **Interfaces:** is not swallowed (#419 review) =="
#
# plan-shape.md's own template always puts a blank line between `**Files:**` and `**Interfaces:**`
# (as does every real plan this suite fixtures against), but nothing upstream enforces that blank
# line. Before this guard, a missing one let the Interfaces text get appended to the Files payload
# as a bogus continuation — turning a perfectly fresh plan into a false MISSING/exit 5.
cat > "$WORK/no-blank-before-interfaces.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: no blank line
**Files:** modify `a.sh`.
**Interfaces:** consumes `Foo.Bar`; produces `Baz.Qux`.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C35 no blank before Interfaces: 0  " 0 "$WORK/no-blank-before-interfaces.md"
want_line "C36 …the real path is OK, not eaten" "OK modify a.sh (Task 1)"

echo "== …and two **Files:** lines under one task start two fields, not a merge (#419 Spec edge case) =="
cat > "$WORK/two-files-lines.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: two Files lines

**Files:** modify `a.sh`.
**Files:** modify `dir with space/b.sh`.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C37 two Files: lines both parse    " 0 "$WORK/two-files-lines.md"
want_line "C38 …the first line's path is OK  " "OK modify a.sh (Task 1)"
want_line "C39 …the second line's path is OK " "OK modify dir with space/b.sh (Task 1)"

echo "== a CRLF plan body is read, not reported stale (found in review of #322) =="
#
# The plan arrives via `gh api … --jq .body`, and a body authored in GitHub's web editor is CRLF.
# The stray \r rode the last item of every **Files:** line and made it MISSING — with a diagnostic
# that printed identically to the path it was complaining about.
printf '## \xf0\x9f\x9b\xa0\xef\xb8\x8f Implementation plan\r\n\r\n### Task 1: crlf\r\n\r\n**Files:** modify `a.sh`; modify `dir with space/b.sh`.\r\n' > "$WORK/crlf.md"
run_case "C13 a CRLF plan is exit 0         " 0 "$WORK/crlf.md"
want_line "C14 …with the CR off the path    " "OK modify dir with space/b.sh (Task 1)"

echo "== a path is passed LITERALLY — brackets included =="
mkdir -p "$REPO/odd"
printf 'z\n' > "$REPO/odd/[bracketed].sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "a bracketed path"
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
cat > "$WORK/bracket.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: brackets

**Files:** modify `odd/[bracketed].sh`.
PLAN
run_case "C15 a [bracketed] path resolves   " 0 "$WORK/bracket.md"
want_line "C16 …and is reported verbatim    " "OK modify odd/[bracketed].sh (Task 1)"

echo "== the other bold spelling is READ, not silently skipped =="
cat > "$WORK/altbold.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the other spelling

**Files**: modify `gone.sh`.
PLAN
run_case "C17 **Files**: is parsed too      " 5 "$WORK/altbold.md"
want_line "C18 …and its stale path is named " "MISSING modify gone.sh (Task 1)"

echo "== a task's own \"no file\" idiom is not a path (#403) =="
#
# `create-issue`'s own doctrine (skills/_shared/plan-shape.md) writes `**Files:** none expected.`
# on a verification-only task — every issue filed under it does, #396's Task 4 and #372's Task 4
# among them. Treating that phrase as a path name reports a fresh plan STALE on every such task.
cat > "$WORK/no-file.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: verify the fix

**Files:** none expected.

- [ ] **Step 1:** run the suite and confirm it is green.
PLAN
run_case "C24 a 'none expected' task exits 0 " 0 "$WORK/no-file.md"
if grep -Eq 'MISSING|^OK |^SKIP' "$OUT"; then
  note_fail "C25 …and prints no verdict line   — got:"
  sed 's/^/      /' "$OUT"
else
  note_ok "C25 …and prints no verdict line   "
fi

echo "== …but a real-looking path is still checked, not waved through (#403) =="
#
# The negative: one word changed (`none expected` -> `none-such.md`) must flip exit 0 back to 5 —
# proving "none" did not become a magic word that hides a typo.
cat > "$WORK/no-file-typo.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: verify the fix

**Files:** modify none-such.md

- [ ] **Step 1:** run the suite and confirm it is green.
PLAN
run_case "C26 a real-looking path still stales" 5 "$WORK/no-file-typo.md"
want_line "C27 …and is named MISSING          " "MISSING modify none-such.md (Task 1)"

echo "== a parenthetical after the no-file phrase is still no-file (#403 Spec edge case) =="
#
# create-issue's own template pattern for asides (proven above at C11/C12) composes with this
# idiom too: `none expected (the PR description records the check).` The payload-level
# parenthetical strip (the C11/C12 machinery) removes the aside before the no-file list is ever
# consulted, so the leading `none expected` is what the list actually sees.
cat > "$WORK/no-file-aside.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: verify the fix

**Files:** none expected (the PR description records the check).

- [ ] **Step 1:** run the suite and confirm it is green.
PLAN
run_case "C28 'none expected (aside)' exits 0 " 0 "$WORK/no-file-aside.md"
if grep -Eq 'MISSING|^OK |^SKIP' "$OUT"; then
  note_fail "C29 …and prints no verdict line   — got:"
  sed 's/^/      /' "$OUT"
else
  note_ok "C29 …and prints no verdict line   "
fi

echo "== every no-verdict condition is exit 2 — none of them may read as 'fresh' =="
#
# Exit 2 is the code that says the question was never answered. Only the task-less case was driven
# before; the empty-plan guard the script's own header calls load-bearing had no test at all, which
# is the shape of hole this repo keeps closing.
: > "$WORK/empty.md"
run_case "C19 an EMPTY plan refuses         " 2 "$WORK/empty.md"
run_case "C20 an unresolvable --base refuses" 2 "$WORK/all-present.md" --base no/such/ref
if "$SCRIPT" -C "$REPO" > "$OUT" 2>&1; then
  note_fail "C21 no plan file refuses          — exited 0 with no plan argument"
else
  [ "$?" = 2 ] && note_ok "C21 no plan file refuses          " \
    || note_fail "C21 no plan file refuses          — wrong exit code"
fi
NOTREPO=$(kit_scratch)
if "$SCRIPT" -C "$NOTREPO" "$WORK/all-present.md" > "$OUT" 2>&1; then
  note_fail "C22 a non-repository refuses      — exited 0 outside a git repo"
else
  [ "$?" = 2 ] && note_ok "C22 a non-repository refuses      " \
    || note_fail "C22 a non-repository refuses      — wrong exit code"
fi

echo "== the shipped script parses under the #131 rules, like every suite does =="
#
# `parse-sweep.sh` with no arguments sweeps tests/*/test.sh only, so the SCRIPT this suite exists
# for is not covered by the CI step that runs it bare. Reuse the shipped tool rather than a second
# `bash -n`: it also carries the static scan for the bash 3.2 heredoc-in-$( … ) construct, which a
# modern bash's parser cannot see.
if "$KIT_ROOT/scripts/parse-sweep.sh" "skills/implement-issue/scripts/plan-freshness.sh" \
     > "$WORK/sweep.log" 2>&1; then
  note_ok "C23 plan-freshness.sh parse-sweeps"
else
  note_fail "C23 plan-freshness.sh parse-sweeps — parse-sweep refused:"
  sed 's/^/      /' "$WORK/sweep.log"
fi

echo "== SKILL.md Step 2 must RUN the freshness pass and carry a STALE list (#322) =="
STEP2=$(section "$SKILL" "## Step 2 — " "## Step 3 — ")
want_in "P1 Step 2 calls plan-freshness.sh " "$STEP2" "plan-freshness.sh"
want_in "P2 Step 2 names the STALE list    " "$STEP2" "STALE:"
want_in "P3 Step 2 re-anchors via Interfaces" "$STEP2" "**Interfaces:**"

echo "== github-mechanics §2b must carry the call and the re-anchor recipe =="
[ -r "$MECHANICS" ] || { echo "FAIL: $MECHANICS missing"; exit 1; }
# Scoped to §2b for the same reason the SKILL.md assertions are scoped per step: a mention parked
# in §5 would satisfy a whole-file grep while §2b said nothing at all.
SEC2B=$(section "$MECHANICS" "### 2b. " "## 3. ")
want_in "P4 §2b spells the freshness call  " "$SEC2B" "plan-freshness.sh"
want_in "P5 §2b spells the re-anchor search" "$SEC2B" "grep -l -F --"
want_in "P6 §2b names the STALE record     " "$SEC2B" "STALE:"

echo "== Step 3 must explore ONCE and hand later sub-agents a pointer (#322) =="
STEP3=$(section "$SKILL" "## Step 3 — " "## Step 4 — ")
want_in "P7 Step 3 names the notes file    " "$STEP3" 'issue-$ISSUE-notes.md'
want_in "P8 Step 3 says pointer, not copy  " "$STEP3" "pointer"

echo "== Step 6's failing test must cross the seam the plan named (#310, #322) =="
STEP6=$(section "$SKILL" "## Step 6 — " "## Step 7 — ")
want_in "P9 Step 6 names the seam preamble " "$STEP6" "Seams under test"
want_in "P10 Step 6 links the seam doctrine" "$STEP6" "_shared/test-seams.md"

echo "== Step 7 must review on a SECOND axis, against the Spec (#322) =="
if [ -r "$SPEC_REVIEW" ]; then
  note_ok "P11 references/spec-review.md exists"
else
  note_fail "P11 references/spec-review.md exists — $SPEC_REVIEW is missing"
fi
STEP7=$(section "$SKILL" "## Step 7 — " "## Step 8 — ")
want_in "P12 Step 7 links the Spec brief   " "$STEP7" "](references/spec-review.md)"
want_in "P13 Step 7 routes creep to the PR " "$STEP7" "### Follow-ups"
want_in "P14 Step 7 refuses to rerank      " "$STEP7" "rerank"

# The credit is a licence obligation, not decoration: the brief, the a/b/c categories, the smell
# baseline and the two-heading aggregation are Matt Pocock's, taken under MIT.
want_in "P15 the brief credits its source  " "$SPEC_REVIEW" "mattpocock/skills"
want_in "P16 the brief carries the a/b/c   " "$SPEC_REVIEW" "scope creep"
want_in "P17 the brief bounds its length   " "$SPEC_REVIEW" "400 words"
# The Spec is fetched from an issue body — foreign text. A reference that ingests it and does not
# carry the boundary is the #266 failure one file over.
want_in "P18 the brief reads it as data    " "$SPEC_REVIEW" "untrusted-input-boundary.md"

echo "== Step 10 must REPORT both new verdicts — an unreported check is no check (#322) =="
STEP10=$(section "$SKILL" "## Step 10 — " "## Notes on quality")
want_in "P19 Step 10 reports freshness    " "$STEP10" "Plan freshness"
want_in "P20 Step 10 reports the Spec axis" "$STEP10" "Spec axis"

[ "$FAILED" -eq 0 ] || exit 1
echo "plan-freshness golden test: all cases behaved as specified"
