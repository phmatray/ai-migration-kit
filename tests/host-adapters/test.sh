#!/usr/bin/env bash
# Golden test for scripts/host-adapters.py — the generator and drift check for the files that carry
# one of the kit's sources to another host (#525): AGENTS.md's rule copies for Cursor, Windsurf,
# Cline, Kiro, GitHub Copilot and Antigravity.
#
# What this suite guards:
#   A. the REAL repository                      -> check exits 0, every copy in step
#   B. one copy edited in a scratch tree        -> exit 1, naming that copy and no other
#   C. build in that tree, then check           -> exit 0 — build restores what check refuses
#   D. a copy deleted in a scratch tree         -> exit 1, naming it (absence is drift)
#   E. a scratch tree with no AGENTS.md         -> exit 2, no verdict, never a pass
#   F. a copy with CRLF line endings            -> exit 0 (a Windows checkout is not drift)
#   G. no subcommand                            -> exit 2 (usage)
#   H. each host's front matter, on the real copies, as the host documents it
#
# Expected paths and front matter are literals here, never read back out of the script: a test
# that recomputed them the way the script does could never disagree with it (tautological).
# Section lines carry a label, never a fraction.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/host-adapters.py"
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

COPIES=".cursor/rules/ai-migration-kit.mdc .windsurf/rules/ai-migration-kit.md .clinerules/ai-migration-kit.md .kiro/steering/ai-migration-kit.md .github/copilot-instructions.md .agents/rules/ai-migration-kit.md"

# scratch_tree <dir> — a copy of what the check reads, and nothing else.
scratch_tree() {
  local d="$1" f
  mkdir -p "$d"
  cp "$REPO/AGENTS.md" "$d/AGENTS.md"
  for f in $COPIES; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$REPO/$f" "$d/$f" 2>/dev/null || true
  done
}

# run_check <repo> [subcommand] — sets OUT (stdout+stderr) and RC.
run_check() {
  OUT=$(python3 "$CHECK" --repo "$1" "${2:-check}" 2>&1)
  RC=$?
}

names() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

[ -f "$CHECK" ] || { echo "FAIL: $CHECK does not exist"; exit 1; }

echo "== A. the real repository =="
run_check "$REPO"
[ "$RC" -eq 0 ] && ok "check exits 0 on the live tree" || bad "check exited $RC on the live tree: $OUT"

echo "== B. one edited copy is refused, by name =="
T="$WORK/b"; scratch_tree "$T"
printf '\nA line nobody generated.\n' >> "$T/.clinerules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT"
names ".clinerules/ai-migration-kit.md" && ok "names .clinerules/ai-migration-kit.md" || bad "does not name the edited copy: $OUT"
names ".kiro/steering/ai-migration-kit.md" && bad "names an untouched copy: $OUT" || ok "names no untouched copy"

echo "== C. build restores it =="
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build exits 0" || bad "build exited $RC: $OUT"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== D. a missing copy is drift =="
T="$WORK/d"; scratch_tree "$T"
rm "$T/.kiro/steering/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT"
names ".kiro/steering/ai-migration-kit.md" && ok "names the missing copy" || bad "does not name the missing copy: $OUT"

echo "== E. no AGENTS.md, no verdict =="
T="$WORK/e"; scratch_tree "$T"
rm "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "exit 2" || bad "exit $RC, want 2: $OUT"

echo "== F. CRLF is not drift =="
T="$WORK/f"; scratch_tree "$T"
awk '{ printf "%s\r\n", $0 }' "$REPO/.clinerules/ai-migration-kit.md" > "$T/.clinerules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "a CRLF copy is in step" || bad "exit $RC on a CRLF copy: $OUT"

echo "== G. usage =="
OUT=$(python3 "$CHECK" --repo "$REPO" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "no subcommand exits 2" || bad "no subcommand exited $RC"

echo "== H. each host's front matter =="
[ "$(head -1 "$REPO/.cursor/rules/ai-migration-kit.mdc")" = "---" ] \
  && grep -qx 'alwaysApply: true' "$REPO/.cursor/rules/ai-migration-kit.mdc" \
  && ok "Cursor: an always-applied .mdc rule" || bad "Cursor rule lacks 'alwaysApply: true' front matter"
grep -qx 'trigger: always_on' "$REPO/.windsurf/rules/ai-migration-kit.md" \
  && ok "Windsurf: trigger always_on" || bad "Windsurf rule lacks 'trigger: always_on'"
grep -qx 'inclusion: always' "$REPO/.kiro/steering/ai-migration-kit.md" \
  && ok "Kiro: inclusion always" || bad "Kiro steering lacks 'inclusion: always'"
for f in .clinerules/ai-migration-kit.md .github/copilot-instructions.md .agents/rules/ai-migration-kit.md; do
  [ "$(head -1 "$REPO/$f")" = "# AI Migration Kit" ] \
    && ok "$f: no front matter, opens on the heading" || bad "$f does not open on '# AI Migration Kit'"
done

if [ "$fails" -eq 0 ]; then
  echo "PASS: host-adapters — live tree, edit, rebuild, missing copy, no source, CRLF, usage, front matter"
else
  echo "FAIL: host-adapters — $fails assertion(s) failed"; exit 1
fi
