#!/usr/bin/env bash
# Golden test for scripts/session-retro.sh — the weekly trigger that runs the deterministic half
# of review-sessions so the evidence stops waiting for someone to remember.
#
# Fail-path first, because the defect this suite exists to pin was found by hand and would have
# stayed green forever: harvest.py prints a FOOTER on every run ("no signals across N session(s)",
# "skipped N unparseable line(s)"), so the first version's "is the report empty?" test never fired
# and the timer would have notified every single week with a report containing nothing. §1 is that
# case, and it is the one that matters — a notifier that cries wolf weekly gets muted, and then the
# whole loop is off again with CI green.
#
# §4 pins the other silent failure: install MUST resolve the repository through
# scripts/main-worktree.sh (#125), never $PWD. Installed from inside an implement-issue worktree,
# a $PWD-derived unit points ExecStart at a directory that is deleted when the PR lands — a timer
# that fails silently from then on.
#
# Everything runs against a FAKE kit tree with a stub harvest.py, so the suite never depends on
# what happens to be in ~/.claude/projects and never spawns anything.
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRIPT="./scripts/session-retro.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

# A fake kit whose harvest.py emits exactly $1 as its --json output. session-retro.sh derives KIT
# from its own BASH_SOURCE, so a copy under a scratch tree reads the stub and nothing else.
make_kit() {
  local root harvest
  root=$(kit_scratch)
  mkdir -p "$root/scripts" "$root/skills/review-sessions/scripts"
  cp "$KIT/scripts/session-retro.sh" "$root/scripts/"
  harvest="$root/skills/review-sessions/scripts/harvest.py"
  cat >"$harvest" <<PY
#!/usr/bin/env python3
import sys
# Every real run ends with this footer, on BOTH paths. That is the whole point of §1.
if "--json" in sys.argv:
    sys.stdout.write('''$1''')
else:
    sys.stdout.write("## stub\n\n| kind | count |\n|---|---:|\n")
sys.stdout.write("skipped 0 unparseable line(s) - never-wait phrases: kit\n")
PY
  chmod +x "$harvest"
  # install must read the repo path from here, never from \$PWD (§4).
  printf '#!/usr/bin/env bash\necho /the/main/checkout\n' >"$root/scripts/main-worktree.sh"
  chmod +x "$root/scripts/main-worktree.sh"
  echo "$root"
}

# ------------------------------------------------------------------ §1 no records, footer only
# The regression: output is NOT empty (the footer is always there), yet there is nothing to report.
root=$(make_kit "")
out=$(kit_scratch)
res=$(KIT_RETRO_DIR="$out" "$root/scripts/session-retro.sh" run)
case "$res" in
  *"no signals"*) ;;
  *) echo "FAIL: a footer-only harvest must report no signals, got: $res"; exit 1 ;;
esac
if [ -n "$(ls -A "$out")" ]; then
  echo "FAIL: a footer-only harvest wrote a report — the weekly notification would cry wolf:"
  ls -l "$out"
  exit 1
fi
echo "  ok §1: harvest's always-present footer is not mistaken for a signal"

# ------------------------------------------------------------------------- §2 records → report
root=$(make_kit '{"kind":"tool-error","skill":"merge-pr"}
{"kind":"hook-deny","skill":"implement-issue"}
')
out=$(kit_scratch)
res=$(KIT_RETRO_DIR="$out" "$root/scripts/session-retro.sh" run)
[ -f "$res" ] || { echo "FAIL: run printed '$res', which is not a file"; exit 1; }
grep -q '^# Session retro — 2 kit failure signal(s) since ' "$res" || {
  echo "FAIL: the report's heading must carry the record COUNT, so a reader knows the size"
  echo "      of the retro before opening it. Got:"; head -1 "$res"; exit 1; }
grep -q '/review-sessions --since ' "$res" || {
  echo "FAIL: the report must name the command that turns it into filed issues — the harvest is"
  echo "      the trigger, not the retro."; exit 1; }
echo "  ok §2: records produce a counted report that hands off to the skill"

# --------------------------------------------------------- §3 an unknown verb refuses, loudly
root=$(make_kit "")
set +e
"$root/scripts/session-retro.sh" bogus >/dev/null 2>&1; rc=$?
"$root/scripts/session-retro.sh" >/dev/null 2>&1; rc_bare=$?
set -e
[ "$rc" -eq 2 ] && [ "$rc_bare" -eq 2 ] || {
  echo "FAIL: an unknown or missing verb must exit 2, got $rc / $rc_bare"; exit 1; }
echo "  ok §3: an unknown or missing verb refuses with exit 2"

# ------------------------------------ §4 install resolves the MAIN checkout, never the worktree
root=$(make_kit "")
units=$(kit_scratch)
stub=$(kit_scratch)
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/systemctl"; chmod +x "$stub/systemctl"
( cd "$root" && PATH="$stub:$PATH" XDG_CONFIG_HOME="$units" \
    ./scripts/session-retro.sh install >/dev/null )
svc="$units/systemd/user/kit-session-retro.service"
[ -f "$svc" ] && [ -f "$units/systemd/user/kit-session-retro.timer" ] || {
  echo "FAIL: install did not write both unit files under $units"; exit 1; }
grep -q '^ExecStart=/the/main/checkout/scripts/session-retro.sh run$' "$svc" || {
  echo "FAIL: ExecStart must come from scripts/main-worktree.sh. A \$PWD-derived path installed"
  echo "      from a linked worktree dies with that worktree and the timer fails silently. Got:"
  grep '^ExecStart=' "$svc"; exit 1; }
grep -q '^Persistent=true$' "$units/systemd/user/kit-session-retro.timer" || {
  echo "FAIL: the timer must be Persistent — a machine asleep on Monday must still run the retro"
  echo "      when it wakes, or a whole week of evidence is skipped with nothing to show it."
  exit 1; }
echo "  ok §4: install points at the main checkout and survives a missed window"

echo "session-retro golden test OK"
