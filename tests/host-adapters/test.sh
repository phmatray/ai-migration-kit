#!/usr/bin/env bash
# Golden test for scripts/host-adapters.py — the generator and drift check for the files that carry
# one of the kit's sources to another host (#525): AGENTS.md's rule copies for Cursor, Windsurf,
# Cline, Kiro, GitHub Copilot and Antigravity.
#
# What this suite guards:
#   A. the REAL repository                      -> check exits 0, every copy in step
#   B. one copy edited in a scratch tree        -> exit 1, naming that copy and no other
#   C. build in that tree, then check           -> exit 0 — build restores what check refuses
#   D. a copy's whole folder deleted            -> exit 1, naming it; build recreates the folder
#   E. a scratch tree with no AGENTS.md         -> exit 2, no verdict, never a pass
#   F. a copy with CRLF line endings            -> exit 0 (a Windows checkout is not drift)
#  F2. a UTF-16 copy / a UTF-16 AGENTS.md       -> exit 1 naming it / exit 2 — never a traceback
#  F4. a CRLF AGENTS.md                         -> exit 0 (the source is normalised too)
#   G. no subcommand                            -> exit 2 (usage)
#   H. each host's front matter, on the real copies, as the host documents it
#
# The seam is the check's exit code and its STDOUT: a refusal is named there, and stderr is read
# only to prove no traceback escaped. Expected paths and front matter are literals here, never read
# back out of the script — a test that recomputed them the way the script does could never
# disagree with it (tautological). Section lines carry a label, never a fraction.
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

# run_check <repo> [subcommand] — sets OUT (stdout), ERR (stderr) and RC.
run_check() {
  OUT=$(python3 "$CHECK" --repo "$1" "${2:-check}" 2>"$WORK/stderr")
  RC=$?
  ERR=$(cat "$WORK/stderr")
}

names() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
no_traceback() { case "$ERR" in *Traceback*) bad "$1 produced a traceback: $ERR" ;; *) ok "$1: no traceback" ;; esac; }
utf16() { python3 -c 'import sys; open(sys.argv[2], "w", encoding="utf-16").write(open(sys.argv[1], encoding="utf-8").read())' "$1" "$2"; }
crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$2"; }

[ -f "$CHECK" ] || { echo "FAIL: $CHECK does not exist"; exit 1; }

echo "== A. the real repository =="
run_check "$REPO"
[ "$RC" -eq 0 ] && ok "check exits 0 on the live tree" || bad "check exited $RC on the live tree: $OUT $ERR"

echo "== B. one edited copy is refused, by name =="
T="$WORK/b"; scratch_tree "$T"
printf '\nA line nobody generated.\n' >> "$T/.clinerules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names ".clinerules/ai-migration-kit.md" && ok "names .clinerules/ai-migration-kit.md on stdout" || bad "stdout does not name the edited copy: $OUT"
names ".kiro/steering/ai-migration-kit.md" && bad "names an untouched copy: $OUT" || ok "names no untouched copy"

echo "== C. build restores it =="
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build exits 0" || bad "build exited $RC: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== D. a copy's whole folder deleted is drift, and build recreates it =="
T="$WORK/d"; scratch_tree "$T"
rm -r "$T/.kiro"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names ".kiro/steering/ai-migration-kit.md" && ok "names the missing copy on stdout" || bad "stdout does not name the missing copy: $OUT"
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build recreates the missing folder" || bad "build exited $RC into a missing folder: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== E. no AGENTS.md, no verdict =="
T="$WORK/e"; scratch_tree "$T"
rm "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "exit 2" || bad "exit $RC, want 2: $OUT $ERR"
no_traceback "a missing AGENTS.md"

echo "== F. CRLF is not drift =="
T="$WORK/f"; scratch_tree "$T"
crlf "$REPO/.clinerules/ai-migration-kit.md" "$T/.clinerules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "a CRLF copy is in step" || bad "exit $RC on a CRLF copy: $OUT"

echo "== F2. a non-UTF-8 file: a copy is drift, the source is no verdict =="
T="$WORK/f2"; scratch_tree "$T"
utf16 "$REPO/.windsurf/rules/ai-migration-kit.md" "$T/.windsurf/rules/ai-migration-kit.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "a UTF-16 copy exits 1" || bad "a UTF-16 copy exited $RC, want 1: $OUT $ERR"
names ".windsurf/rules/ai-migration-kit.md" && ok "names the UTF-16 copy on stdout" || bad "stdout does not name the UTF-16 copy: $OUT"
no_traceback "a UTF-16 copy"
T="$WORK/f3"; scratch_tree "$T"
utf16 "$REPO/AGENTS.md" "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "a UTF-16 AGENTS.md exits 2" || bad "a UTF-16 AGENTS.md exited $RC, want 2: $OUT $ERR"
no_traceback "a UTF-16 AGENTS.md"

echo "== F4. a CRLF AGENTS.md is not drift =="
T="$WORK/f4"; scratch_tree "$T"
crlf "$REPO/AGENTS.md" "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "LF copies are in step with a CRLF source" || bad "exit $RC with a CRLF AGENTS.md: $OUT"

echo "== G. usage =="
python3 "$CHECK" --repo "$REPO" > /dev/null 2>&1; RC=$?
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
  echo "PASS: host-adapters — live tree, edit, rebuild, missing folder, no source, CRLF, encodings, usage, front matter"
else
  echo "FAIL: host-adapters — $fails assertion(s) failed"; exit 1
fi
