#!/usr/bin/env bash
# Golden test for skills/review-sessions — the transcript harvest and the skill over it (#397).
#
# The harvest is deterministic and the suite holds it to a planted set: one signal of every kind,
# each after a Skill tool_use naming a kit skill, plus one decoy per class the script must NOT
# collect (a non-kit tool error, a deny from a foreign hook, the harness's own worktree refusal, a
# non-JSON line, a record older than --since). A script that over-collects fails here as loudly as
# one that under-collects: the assertion is on the exact set of (kind, skill) pairs.
#
# The transcript shapes are the ones Claude Code writes today — `type`, `timestamp`, and
# `message.content` blocks of `text` / `tool_use` / `tool_result` — pinned by construction in the
# writer below, the same way tests/usage-report/test.sh pins the usage shape.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged

SCRIPT="$KIT/skills/review-sessions/scripts/harvest.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
SKILL="$KIT/skills/review-sessions/SKILL.md"

# ------------------------------------------------------------------------- fixture writers
# $1 = out file (appended), $2 = type (user|assistant), $3 = timestamp, $4 = JSON for message.content
write_line() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
out, typ, ts, content = sys.argv[1:5]
rec = {"type": typ, "timestamp": ts, "message": {"role": typ, "content": json.loads(content)}}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
}
tool_use() { # $1 id  $2 name  $3 input JSON
  printf '[{"type":"tool_use","id":"%s","name":"%s","input":%s}]' "$1" "$2" "$3"
}
tool_result() { # $1 id  $2 text  $3 is_error (true|false)
  python3 -c 'import json,sys; print(json.dumps([{"type":"tool_result","tool_use_id":sys.argv[1],"content":sys.argv[2],"is_error":sys.argv[3]=="true"}]))' "$1" "$2" "$3"
}
text() { python3 -c 'import json,sys; print(json.dumps([{"type":"text","text":sys.argv[1]}]))' "$1"; }

PROJ=$(kit_scratch)/-Users-me-repo-ai-migration-kit    # the dir name carries the kit name → in-kit paths count
mkdir -p "$PROJ"
T="$PROJ/sess-1.jsonl"
D="2026-08-20T10:00:00.000Z"

# The skill that owns everything below.
write_line "$T" assistant "$D" "$(tool_use t0 Skill '{"skill":"ai-migration-kit:implement-issue","args":"47"}')"
# 1. tool-error: an is_error on a kit script.
write_line "$T" assistant "$D" "$(tool_use t1 Bash '{"command":"./skills/implement-issue/scripts/tick-plan.sh --issue 47"}')"
write_line "$T" user "$D" "$(tool_result t1 'tick-plan: gh api timed out' true)"
# decoy: an is_error on a non-kit command.
write_line "$T" assistant "$D" "$(tool_use t2 Bash '{"command":"/usr/bin/foo --bar"}')"
write_line "$T" user "$D" "$(tool_result t2 'foo: command not found' true)"
# 2. hook-deny: the kit's write-gate.
write_line "$T" assistant "$D" "$(tool_use t3 Bash '{"command":"git commit -m x"}')"
write_line "$T" user "$D" "$(tool_result t3 'Blocked by the git write-gate: `git commit -m x` is one of the writes that produced #26 and #280 in a shared checkout.' true)"
# decoy: a deny from a foreign hook.
write_line "$T" assistant "$D" "$(tool_use t4 Grep '{"pattern":"class Foo"}')"
write_line "$T" user "$D" "$(tool_result t4 'roseline-nudge: prefer search_symbols over Grep for C#' true)"
# decoy: the harness worktree refusal (not the kit).
write_line "$T" assistant "$D" "$(tool_use t5 Bash '{"command":"git -C /elsewhere status"}')"
write_line "$T" user "$D" "$(tool_result t5 'This session is isolated in the worktree /x, but this command redirects git to the shared checkout via -C. Refusing to run it.' true)"
# 3. forbidden-wait.
write_line "$T" assistant "$D" "$(text "The suite is running. I'll pause here and wait for the code-review report before continuing.")"
# 4. worker-report.
write_line "$T" assistant "$D" "$(text 'PHASE1 | ISSUE: 47 | PR: none | STATUS: BLOCKED | DETAIL: no usable plan | FILED: none')"
# 5. suite-fail: a kit golden suite's FAIL line inside a tool result.
write_line "$T" assistant "$D" "$(tool_use t6 Bash '{"command":"./tests/survey/test.sh"}')"
write_line "$T" user "$D" "$(tool_result t6 'ok: frontier
FAIL: SKILL.md Step 4 does not carry the immediate re-survey trigger (tests/survey/test.sh case 12d)' true)"
# 6. guard-refusal.
write_line "$T" assistant "$D" "$(tool_use t7 Bash '{"command":"\"$GUARDS/guarded-push.sh\" -C \"$WORKTREE\" feat/47-x"}')"
write_line "$T" user "$D" "$(tool_result t7 'guarded-push.sh: origin/feat/47-x is NOT this HEAD — exit 4' true)"
# 7. harness-nudge (a plain user string).
python3 - "$T" "$D" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps({"type": "user", "timestamp": ts, "message": {"role": "user", "content": "[Request interrupted by user]"}}) + "\n")
PY
# decoys: a non-JSON line, and an old kit tool-error --since must drop.
printf 'not json at all\n' >> "$T"
write_line "$T" assistant "2026-08-01T09:00:00.000Z" "$(tool_use t8 Bash '{"command":"./skills/auto-dev/scripts/survey.sh"}')"
write_line "$T" user "2026-08-01T09:00:00.000Z" "$(tool_result t8 'survey.sh: jq: parse error' true)"

# ------------------------------------------------------------------------- the harvest, JSON
OUT=$(kit_scratch)/records.jsonl
python3 "$SCRIPT" "$PROJ" --json --since 2026-08-15 > "$OUT" 2>"$OUT.err" || {
  echo "FAIL: harvest.py exited non-zero on the fixture"; cat "$OUT.err"; exit 1; }
python3 - "$OUT" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
pairs = sorted({(r["kind"], r["skill"]) for r in recs})
want = sorted({(k, "implement-issue") for k in
               ("tool-error", "hook-deny", "forbidden-wait", "worker-report", "suite-fail", "guard-refusal", "harness-nudge")})
if pairs != want:
    print("FAIL: (kind, skill) set differs from the planted set")
    print("  got :", pairs); print("  want:", want); sys.exit(1)
keys = {"kind", "skill", "session", "path", "ts", "excerpt", "tool", "detail", "count"}
bad = [r for r in recs if set(r) != keys]
if bad:
    print("FAIL: a record does not carry the documented keys:", bad[0]); sys.exit(1)
old = [r for r in recs if r["ts"].startswith("2026-08-01")]
if old:
    print("FAIL: --since did not drop the record dated before it:", old[0]); sys.exit(1)
tool_err = [r for r in recs if r["kind"] == "tool-error"]
if len(tool_err) != 1 or "tick-plan.sh" not in tool_err[0]["detail"]:
    print("FAIL: exactly one tool-error, on tick-plan.sh, was expected:", tool_err); sys.exit(1)
print("ok   the JSON records are exactly the planted set, keyed as documented, and --since holds")
PY

# ------------------------------------------------------------------------- the tally, markdown
MD=$(kit_scratch)/tally.md
python3 "$SCRIPT" "$PROJ" --markdown --since 2026-08-15 > "$MD" 2>/dev/null || { echo "FAIL: --markdown exited non-zero"; exit 1; }
grep -q '^## implement-issue$' "$MD" || { echo "FAIL: the tally has no per-skill heading"; cat "$MD"; exit 1; }
grep -q '^signals: 7 across 1 sessions' "$MD" || { echo "FAIL: the tally does not end with 'signals: 7 across 1 sessions'"; tail -3 "$MD"; exit 1; }
grep -q 'skipped 1 unparseable' "$MD" || { echo "FAIL: the non-JSON line was not counted as skipped"; tail -3 "$MD"; exit 1; }
echo "ok   the markdown tally groups by skill and kind, counts the skipped line, ends with the signals line"

# ------------------------------------------------------------------------- refusals
if python3 "$SCRIPT" "$PROJ/does-not-exist" --json > "$OUT.missing" 2>&1; then
  echo "FAIL: a missing project dir must exit non-zero"; exit 1; fi
rc=0; python3 "$SCRIPT" "$PROJ/does-not-exist" --json > "$OUT.missing" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: a missing project dir must exit 2, got $rc"; exit 1; }
if grep -q Traceback "$OUT.missing"; then echo "FAIL: a missing project dir produced a traceback"; cat "$OUT.missing"; exit 1; fi
rc=0; python3 "$SCRIPT" "$PROJ" --since not-a-date > "$OUT.date" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: a malformed --since must exit 2, got $rc"; exit 1; }
rc=0; python3 "$SCRIPT" "$PROJ" --json --markdown > "$OUT.both" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: --json and --markdown together must exit 2 (they are exclusive), got $rc"; exit 1; }
# An EXISTING directory that cannot be listed is not "no signals": glob() would swallow the
# PermissionError and the run would answer clean with exit 0. Skipped as root, who can read anything.
if [ "$(id -u)" -ne 0 ]; then
  LOCKED=$(kit_scratch)/-Users-me-repo-ai-migration-kit-locked; mkdir -p "$LOCKED"; chmod 000 "$LOCKED"
  rc=0; python3 "$SCRIPT" "$LOCKED" --json > "$OUT.locked" 2>&1 || rc=$?
  chmod 755 "$LOCKED"
  [ "$rc" -eq 2 ] || { echo "FAIL: an unreadable (chmod 000) project dir must exit 2, got $rc"; cat "$OUT.locked"; exit 1; }
  if grep -q Traceback "$OUT.locked"; then echo "FAIL: an unreadable project dir produced a traceback"; cat "$OUT.locked"; exit 1; fi
fi
EMPTY=$(kit_scratch)/-Users-me-repo-other; mkdir -p "$EMPTY"
python3 "$SCRIPT" "$EMPTY" --markdown > "$OUT.empty" 2>&1 || { echo "FAIL: an empty project dir must exit 0"; exit 1; }
grep -q '^no signals' "$OUT.empty" || { echo "FAIL: an empty project dir must print the explicit 'no signals' line"; cat "$OUT.empty"; exit 1; }
echo "ok   refusals: missing or unreadable dir → 2 without a traceback, bad --since → 2, --json --markdown → 2, empty dir → 0 and 'no signals'"

# ------------------------------------------------------------------------- the never-wait phrases are READ from the kit's suite
grep -q 'auto-dev-never-wait' "$SCRIPT" || { echo "FAIL: harvest.py does not read the never-wait phrases from tests/auto-dev-never-wait/test.sh"; exit 1; }
grep -q 'never-wait phrases: kit' "$MD" || { echo "FAIL: the tally does not say the never-wait phrases came from the kit's suite"; tail -1 "$MD"; exit 1; }
echo "ok   the never-wait phrase list has one home, and the tally names its source"

# ------------------------------------------------------------------------- the skill's prose
[ -f "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }
grep -q '^name: review-sessions$' "$SKILL" || { echo "FAIL: SKILL.md does not declare name: review-sessions"; exit 1; }
for ref in _shared/recap.md _shared/preconditions.md _shared/filing-bar.md _shared/prior-rejections.md _shared/untrusted-input-boundary.md; do
  grep -qF -- "../$ref" "$SKILL" || { echo "FAIL: SKILL.md does not link ../$ref"; exit 1; }
done
grep -qF 'auto-dev/references/retro-taxonomy.md' "$SKILL" || { echo "FAIL: SKILL.md does not reuse the retro taxonomy"; exit 1; }
grep -qF 'scripts/harvest.py' "$SKILL" || { echo "FAIL: SKILL.md never names scripts/harvest.py"; exit 1; }
grep -qF -- '--dry-run' "$SKILL" || { echo "FAIL: SKILL.md offers no --dry-run"; exit 1; }
grep -qi 'already fixed' "$SKILL" || { echo "FAIL: SKILL.md has no 'already fixed' outcome"; exit 1; }
grep -qF 'create-issue' "$SKILL" || { echo "FAIL: SKILL.md never names create-issue as the filing path"; exit 1; }
if grep -q 'gh issue create' "$SKILL"; then echo "FAIL: SKILL.md files with a raw gh issue create instead of create-issue"; exit 1; fi
if grep -q 'gh issue close' "$SKILL"; then echo "FAIL: SKILL.md closes issues — this skill never closes anything"; exit 1; fi
echo "ok   the skill links its five shared references and the taxonomy, files only through create-issue, never closes"

echo "review-sessions golden test OK"
