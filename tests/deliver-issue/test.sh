#!/usr/bin/env bash
# Golden test for skills/deliver-issue — the single-item orchestrator (#396).
#
# deliver-issue ships no script: its whole mechanism is two existing command files
# (commands/auto-dev-worker.md, commands/auto-dev-merge.md), one existing script
# (skills/auto-dev/scripts/wait-ci.sh) and the Agent tool. So what a suite can hold is the
# POINTERS — the skill must dispatch those files rather than re-spell a worker prompt of its own
# (a second copy of the PHASE1 report contract is exactly the drift tests/auto-dev-never-wait
# exists to stop) — and the three decisions the skill adds between them: the decomposed-filing
# stop, the bounded PARTIAL re-dispatch, and the --stop-at ready opt-out.
#
# Fail-path-first, like every suite here: the "no copied template" rule is driven to red on a
# scratch copy of the skill that carries one, so a check that silently stopped matching cannot pass.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged

SKILL="$KIT/skills/deliver-issue/SKILL.md"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }

# One function, run over the real skill AND over a deliberately broken scratch copy below.
# $1 = the skill file; prints FAIL lines and returns 1 on the first violation.
check_skill() {
  local f="$1"
  grep -q '^name: deliver-issue$' "$f" \
    || { echo "FAIL: $f does not declare name: deliver-issue"; return 1; }

  # 1. The phase prompts are the existing command files, dispatched — never a prompt of its own.
  for p in commands/auto-dev-worker.md commands/auto-dev-merge.md skills/auto-dev/scripts/wait-ci.sh; do
    grep -qF -- "$p" "$f" \
      || { echo "FAIL: $f never names $p — the phase must be dispatched through the existing file, not re-spelled"; return 1; }
  done
  # Anchored at the start of a line's CONTENT — an indented, quoted or bulleted copy is a copy too.
  if grep -qE '^[[:space:]>*-]*PHASE1 \|' "$f"; then
    echo "FAIL: $f carries its own 'PHASE1 |' report template — that contract has one home, commands/auto-dev-worker.md"
    return 1
  fi

  # 2. The three decisions the skill adds, each greppable.
  grep -qF -- '--stop-at ready' "$f" \
    || { echo "FAIL: $f does not offer --stop-at ready (stop before the merge)"; return 1; }
  grep -qF '## Destination' "$f" \
    || { echo "FAIL: $f does not stop on a decomposed filing (a parent carrying '## Destination')"; return 1; }
  grep -qiE 'at most three|three times' "$f" \
    || { echo "FAIL: $f does not bound the PARTIAL re-dispatch to three"; return 1; }
  grep -qF 'PARTIAL' "$f" \
    || { echo "FAIL: $f never handles a PARTIAL phase-1 report"; return 1; }

  # 3. The shared references it must link rather than restate, at the depth a skill links them.
  for ref in _shared/recap.md _shared/preconditions.md _shared/untrusted-input-boundary.md; do
    grep -qF -- "../$ref" "$f" \
      || { echo "FAIL: $f does not link ../$ref"; return 1; }
  done

  # 4. The waiting is the orchestrator's, never the worker's (auto-dev Step 3's ⛔ rule, cited).
  grep -qiE 'never dispatch phase 2 while ci is still pending' "$f" \
    || { echo "FAIL: $f does not carry auto-dev's rule that the orchestrator waits for CI before phase 2"; return 1; }
  return 0
}

check_skill "$SKILL" || exit 1
echo "ok   the skill dispatches the two command files, waits with wait-ci.sh, and states its three decisions"

# ------------------------------------------------------------- the refusal paths, driven to red
scratch=$(kit_scratch)
cp "$SKILL" "$scratch/SKILL.md"
printf '\nPHASE1 | ISSUE: 1 | PR: 2 | STATUS: READY | DETAIL: copied | FILED: none\n' >> "$scratch/SKILL.md"
if check_skill "$scratch/SKILL.md" >/dev/null 2>&1; then
  echo "FAIL: a skill carrying its own PHASE1 report template was accepted"; exit 1
fi
echo "ok   a copied PHASE1 template is refused"

cp "$SKILL" "$scratch/SKILL.md"
python3 - "$scratch/SKILL.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8")
t2 = t.replace("commands/auto-dev-merge.md", "commands/auto-dev-merge-renamed.md")
assert t2 != t, "mutation had no effect"
p.write_text(t2, encoding="utf-8")
PY
if check_skill "$scratch/SKILL.md" >/dev/null 2>&1; then
  echo "FAIL: a skill that lost its pointer to commands/auto-dev-merge.md was accepted"; exit 1
fi
echo "ok   a skill that drops a phase pointer is refused"

# ------------------------------------------------------------- the frontmatter, by the shared gate
python3 "$KIT/tests/skills/check-frontmatter.py" > "$scratch/frontmatter.out" 2>&1 \
  || { echo "FAIL: check-frontmatter.py refuses the tree with deliver-issue in it"; cat "$scratch/frontmatter.out"; exit 1; }
if grep -q 'WARN deliver-issue' "$scratch/frontmatter.out"; then
  echo "FAIL: deliver-issue's description crosses the soft ceiling"; grep 'WARN deliver-issue' "$scratch/frontmatter.out"; exit 1
fi
echo "ok   frontmatter passes the shared gate with no WARN"

echo "deliver-issue golden test OK"
