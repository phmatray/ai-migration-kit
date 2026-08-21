#!/usr/bin/env bash
# Golden test for the decision engine — scripts/decide.sh and scripts/decision-check.py (#208).
#
# What this suite guards, and why it is mostly refusals:
#
#   A. the dispatcher answers                     — every merge.step4 fixture, verdict by verdict,
#      which is what pins the precedence rule itself. Before this suite, five fixtures pinned
#      three of its eight rules: no fixture set isDraft, none carried a non-empty `pending`, none
#      was BLOCKED, none exercised the catch-all. The default could be flipped from `wait` to
#      `merge` with CI green.
#   B. the guard refuses                          — R1 … R9, each driven to RED over a scratch kit.
#
# B is the point. This guard exists because a decision had two homes and the copy nobody ran went
# wrong in silence; a guard whose own refusal path is untested is that same defect one level up. So
# every rule below is asserted by BREAKING a working kit in exactly one way and requiring the
# named rule to fire — never by reading the guard and believing it.
#
# The scratch kit is a real, minimal repository rather than a mock: decision-check.py obtains every
# program by RUNNING `scripts/decide.sh --program <id>` (one home for extraction), and reads program
# modes out of the git INDEX, so a fixture that is not a git repo with a real dispatcher in it would
# exercise neither path. `--repo` is what makes that affordable.
#
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/decision-check.py"
DECIDE="$REPO/scripts/decide.sh"
FIXTURES="$REPO/tests/decisions/fixtures"

# Sourced via $REPO, never $PWD: this suite does not cd, and is written to run from anywhere.
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# ------------------------------------------------------------------------------------ the kit
#
# A working, minimal kit that decision-check.py accepts. Each refusal case copies it and breaks
# exactly one thing, so the rule that fires is attributable to that one change and nothing else.
#
# The program is chosen to exercise the derivations rather than to be realistic: TOKEN_RE reads
# {CLEAN, DIRTY} out of its `== "…"` comparisons (that is R8's whole token set, derived from the
# program and never listed in the registry), and VERDICT_LIT_RE reads {go, stop} out of its
# `verdict:"…"` constructions (that is what R4 holds the declared vocabulary to).
make_kit() {
  local k="$1"
  mkdir -p "$k/scripts" "$k/decisions" "$k/skills/demo/scripts" "$k/tests/demo"

  cp "$DECIDE" "$k/scripts/decide.sh"
  chmod +x "$k/scripts/decide.sh"

  cat > "$k/skills/demo/scripts/prog.sh" <<'PROG'
#!/usr/bin/env bash
set -euo pipefail
jq -c 'if .state == "CLEAN" then {verdict:"go", rule:"clean"}
       elif .state == "DIRTY" then {verdict:"stop", rule:"dirty"}
       else {verdict:"stop", rule:"other"} end'
PROG
  chmod +x "$k/skills/demo/scripts/prog.sh"

  # The owner INVOKES its decision inside a fenced block — that is R7's whole requirement, and the
  # fence matters: prose naming a script is not calling it.
  cat > "$k/skills/demo/SKILL.md" <<'OWNER'
# Demo skill

Step 4 — decide whether to go.

```bash
scripts/decide.sh demo.rule < state.json
```

Apply the verdict:

| Verdict | Do |
|---|---|
| `go` | proceed |
| `stop` | do not |
OWNER

  printf '#!/usr/bin/env bash\nexit 0\n' > "$k/tests/demo/test.sh"
  chmod +x "$k/tests/demo/test.sh"

  cat > "$k/decisions/registry.json" <<'REG'
{
  "description": "scratch kit",
  "decisions": [
    {
      "id": "demo.rule",
      "issue": 0,
      "program": { "kind": "exec", "path": "skills/demo/scripts/prog.sh" },
      "shape": null,
      "owner": "skills/demo/SKILL.md",
      "suites": ["tests/demo/test.sh"],
      "stdin": true,
      "verdict": { "source": "stdout-json", "vocabulary": ["go", "stop"] }
    }
  ]
}
REG

  git -C "$k" init -q
  git -C "$k" add -A
}

# Run the guard over a kit; print nothing, record status and output for the assertions.
run_check() {
  CHECK_OUT=$(python3 "$CHECK" --repo "$1" 2>&1)
  CHECK_RC=$?
}

# Assert the kit is refused as UNANSWERABLE (exit 2) rather than by a numbered rule, naming the
# cause. Two registry defects land here rather than on R9: an unknown `program.kind` and a
# `verdict.source` no dispatcher implements are both refused by `decide.sh --program` itself, which
# decision-check.py runs to obtain every program — so the extraction fails before any rule can be
# evaluated about that row.
#
# That is the right layer (the dispatcher is the one home for extraction, and it names the exact
# cause), but it costs something the guard's own report promises: "All of them, not the first". An
# Unanswerable aborts the whole check, so a registry carrying an unknown kind AND an unrelated R8
# restatement reports only the first. The build goes red either way and the cause is named, so this
# is a recorded limit rather than a defect — written down here so the next reader does not have to
# rediscover which layer refuses what.
unanswerable() {
  local k="$1" needle="$2" label="$3"
  run_check "$k"
  if [ "$CHECK_RC" -ne 2 ]; then
    bad "$label — expected exit 2 (unanswerable), got $CHECK_RC"
    return
  fi
  case "$CHECK_OUT" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label — exited 2, but never named '$needle':"
       printf '%s\n' "$CHECK_OUT" | sed 's/^/          /' ;;
  esac
}

# Assert the guard REFUSES a broken kit, naming the expected rule. A fixture that fails for the
# wrong reason is the failure mode this wrapper exists to stop: it would read as a pass.
refuses() {
  local k="$1" rule="$2" label="$3"
  run_check "$k"
  if [ "$CHECK_RC" -eq 0 ]; then
    bad "$label — the guard PASSED a kit it must refuse"
    return
  fi
  case "$CHECK_OUT" in
    *"$rule"*) ok "$label" ;;
    *) bad "$label — refused, but not by $rule:"
       printf '%s\n' "$CHECK_OUT" | sed 's/^/          /' ;;
  esac
}

echo "== A. the dispatcher answers — every fixture, verdict by verdict"

# The recorded verdicts. Each line is <fixture> <expected-verdict-or-RC2>, and together they pin
# all eight precedence rules plus the two refusal paths. Kept as a here-doc rather than an
# associative array: this must parse under macOS bash 3.2, which has none (scripts/parse-sweep.sh).
while read -r fixture expected; do
  [ -n "$fixture" ] || continue
  out=$("$DECIDE" merge.step4 "$FIXTURES/merge.step4/$fixture" 2>/dev/null)
  rc=$?
  if [ "$expected" = "RC2" ]; then
    if [ "$rc" -eq 2 ]; then ok "$fixture — refused with exit 2, no verdict is not a pass"
    else bad "$fixture — expected exit 2, got $rc ('$out')"; fi
  elif [ "$rc" -ne 0 ]; then
    bad "$fixture — expected verdict '$expected', but decide.sh exited $rc"
  elif [ "$out" = "$expected" ]; then
    ok "$fixture — $expected"
  else
    bad "$fixture — expected '$expected', got '$out'"
  fi
done <<'FIXTURES_EOF'
clean.json merge
behind.json sync
behind-state.json sync
dirty-fresh.json sync
failed.json fix-check
pending.json wait
unstable-quiet.json wait
unknown.json wait
unrecognised.json wait
draft-flag.json ready
draft-state.json ready
blocked-approval.json review
blocked-changes-requested.json review
empty RC2
not-an-object.json RC2
FIXTURES_EOF

echo "== B. the guard refuses"

# --- the happy path first, so every refusal below is attributable to its one mutation ----------
BASE=$(kit_scratch)/kit
mkdir -p "$BASE"
make_kit "$BASE"
run_check "$BASE"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "a coherent kit passes (so the refusals below are caused by their mutation, not by the kit)"
else
  bad "the scratch kit does not pass clean — every case below is meaningless until it does:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- R9 registry integrity ---------------------------------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/"id": "demo.rule"/"id": "Demo.Rule"/' "$k/decisions/registry.json"
refuses "$k" R9 "R9 — a malformed decision id is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/"stdout-json"/"exit-map"/' "$k/decisions/registry.json"
unanswerable "$k" "exit-map" \
  "a verdict.source no dispatcher implements is refused by the dispatcher, exit 2"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
rm -f "$k/tests/demo/test.sh"
refuses "$k" R9 "R9 — a suite listed in the registry but absent is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
rm -f "$k/skills/demo/SKILL.md"
refuses "$k" R9 "R9 — an owner that cannot be read is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/"kind": "exec"/"kind": "inline"/' "$k/decisions/registry.json"
unanswerable "$k" "inline" \
  "an unknown program.kind is refused by the dispatcher, exit 2"

# --- R1 one home, and a program CI can actually execute ----------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
git -C "$k" update-index --chmod=-x skills/demo/scripts/prog.sh 2>/dev/null
refuses "$k" R1 "R1 — a program committed 100644 is refused (CI would die with Permission denied)"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
git -C "$k" rm --cached -q skills/demo/scripts/prog.sh
refuses "$k" R1 "R1 — a program that is not in the git index is refused"

# --- R4 the declared vocabulary is exact -------------------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/{verdict:"stop", rule:"other"}/{verdict:"maybe", rule:"other"}/' \
  "$k/skills/demo/scripts/prog.sh"
git -C "$k" add -A
refuses "$k" R4 "R4 — a verdict the program emits but the registry never declared is refused"

# --- R5 causes are distinct, and a comment quoting the form it documents is not a branch --------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    "set -euo pipefail\n",
    'set -euo pipefail\n# always emits verdict:"stop" when state is not CLEAN\n',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R5 — a comment quoting the verdict form it documents is not counted as an extra branch"
else
  bad "R5 — a documentary comment made the guard refuse a kit that R5 must accept:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- the strip's own limit: a `#` legitimately inside a verdict value must survive intact --------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'else {verdict:"stop", rule:"other"} end',
    'elif .state == "HASH" then {verdict:"needs-#1", rule:"hash"}\n'
    '       else {verdict:"stop", rule:"other"} end',
)
open(p, "w").write(t)
PY
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"vocabulary": ["go", "stop"]', '"vocabulary": ["go", "stop", "needs-#1"]')
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "a '#' legitimately inside a verdict value (needs-#1) is still counted and R4/R5 both pass"
else
  bad "a '#' inside a quoted verdict value was truncated, breaking R4/R5 on an otherwise-coherent kit:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- R7 the owner must INVOKE, not merely mention -----------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
# Delete the fenced call, leaving the skill otherwise intact. This is the exact move that would
# reintroduce #208 with the engine watching: re-derive the verdict by hand and every other rule
# here stays green.
python3 - "$k/skills/demo/SKILL.md" <<'PY'
import sys, re
p = sys.argv[1]
t = open(p).read()
t = t.replace("```bash\nscripts/decide.sh demo.rule < state.json\n```\n", "")
open(p, "w").write(t)
PY
refuses "$k" R7 "R7 — an owner that stopped invoking its own decision is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
# The same call, but OUTSIDE a fence — prose naming a script is not calling it.
python3 - "$k/skills/demo/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("```bash\nscripts/decide.sh demo.rule < state.json\n```\n",
              "Run scripts/decide.sh demo.rule to decide.\n")
open(p, "w").write(t)
PY
refuses "$k" R7 "R7 — an invocation that is only prose, not a fenced call, is refused"

# --- R8 prose may not re-enumerate the states the program tests ---------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'RESTATE'

| State | Then |
|---|---|
| `CLEAN` | go |
| `DIRTY` | stop |
RESTATE
refuses "$k" R8 "R8 — a table re-enumerating the states the program tests is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'ANNOTATED'

<!-- decided-by: demo.rule -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `DIRTY` | stop |
ANNOTATED
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R8 — an explicitly annotated table is allowed (the escape hatch works)"
else
  bad "R8 — the annotation escape hatch does not work:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'OVERREACH'

<!-- decided-by: demo.rule -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `MERGEABLE` | go |
OVERREACH
refuses "$k" R8 "R8 — an annotated table naming a state the program never tests is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'UNKNOWNID'

<!-- decided-by: nope.missing -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `DIRTY` | stop |
UNKNOWNID
refuses "$k" R8 "R8 — an annotation for an unregistered decision is refused"

# --- the claim the whole design rests on --------------------------------------------------------
#
# R8's token set is derived BY REGEX FROM THE PROGRAM TEXT, never from a list in the registry. That
# is the single property that separated the winning design from the losing one: a hand-typed
# vocabulary in the manifest is a second copy, and the manifest of a system whose purpose is to
# abolish second copies is the last place one may live. So: grow the program a NEW branch, restate
# THAT branch as a table, touch the registry not at all — and the guard must still fire.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('elif .state == "DIRTY"',
              'elif .state == "BLOCKED" then {verdict:"stop", rule:"blocked"}\n       elif .state == "DIRTY"')
open(p, "w").write(t)
PY
git -C "$k" add -A
cat >> "$k/skills/demo/SKILL.md" <<'NEWTOKEN'

| State | Then |
|---|---|
| `BLOCKED` | stop |
| `CLEAN` | go |
NEWTOKEN
refuses "$k" R8 "R8 — a NEW program branch restated as a table fires with the registry untouched"

# --- the exit-code contract ----------------------------------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
rm -f "$k/scripts/decide.sh"
run_check "$k"
if [ "$CHECK_RC" -eq 2 ]; then
  ok "exit 2 — with no dispatcher no program can be extracted, and an unanswerable question is not a pass"
else
  bad "expected exit 2 when the dispatcher is absent, got $CHECK_RC"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "decisions: OK — the dispatcher answers, and every rule of the guard goes red on demand."
  exit 0
fi
echo "decisions: $fails failure(s)."
exit 1
