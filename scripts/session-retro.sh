#!/usr/bin/env bash
# session-retro.sh — put the kit's retro on a clock instead of on someone's memory.
#
# `review-sessions` has always been able to read the failures the kit caused; nothing ever ran it.
# Every defect the kit fixed in 2026-08 was found by a human reading transcripts days after the
# evidence had been on disk. This is the trigger that stops that: a weekly systemd user timer that
# runs the DETERMINISTIC half — `skills/review-sessions/scripts/harvest.py`, read-only, stdlib
# only, pinned by tests/review-sessions/test.sh — writes a dated report and notifies when it found
# something.
#
# The judging half stays manual on purpose. harvest.py cannot file, close or edit anything; an
# unattended `claude -p` holding Bash can reach `gh issue create`, and a scheduled inlet that files
# on its own is exactly the thing the filing bar exists to keep a human in front of. The
# notification IS the hand-off: read the report, then type `/review-sessions --since <date>` and
# let the skill cluster, verify against the tree, apply the bar and file.
#
# Usage:
#   session-retro.sh run       harvest the last $KIT_RETRO_DAYS days, write a report, notify
#   session-retro.sh install   write and enable the weekly systemd user timer that calls `run`
#   session-retro.sh uninstall stop and remove it
#
# Environment:
#   KIT_RETRO_DAYS  lookback window in days (default 7)
#   KIT_RETRO_DIR   where reports land (default $XDG_STATE_HOME/ai-migration-kit/retro)
#
# Exit codes: 0 ran (with or without signals) · 1 harvest failed · 2 bad usage

set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAYS="${KIT_RETRO_DAYS:-7}"
STATE="${KIT_RETRO_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ai-migration-kit/retro}"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT=kit-session-retro

harvest() { python3 "$KIT/skills/review-sessions/scripts/harvest.py" --since "$1" "$2"; }

cmd_run() {
  local since out n
  since="$(date -d "$DAYS days ago" +%F)"

  # Count RECORDS, not output: harvest.py prints a footer ("no signals across N session(s)",
  # "skipped N unparseable line(s)") on every run, so a non-empty report is not a signal. --json
  # is JSONL, one object per record, and a record line is the only line that starts with `{`.
  n="$(harvest "$since" --json | grep -c '^{' || true)"
  if [ "$n" -eq 0 ]; then
    echo "session-retro: no signals since $since"
    return 0
  fi

  mkdir -p "$STATE"
  out="$STATE/$(date +%F).md"
  {
    echo "# Session retro — $n kit failure signal(s) since $since"
    echo
    harvest "$since" --markdown
    echo
    echo "_Deterministic harvest only: nothing here is clustered, verified against \`main\`, or"
    echo "filed. Run \`/review-sessions --since $since\` to do that._"
  } >"$out"

  # Best-effort desktop hand-off; a headless timer without a notification daemon still gets the file.
  command -v notify-send >/dev/null 2>&1 && notify-send "Kit retro: $n new failure signal(s)" "$out" || true
  echo "$out"
}

cmd_install() {
  local repo
  # The timer must point at the MAIN checkout, never a linked worktree (scripts/main-worktree.sh
  # is the one home for that derivation), so a run started from inside an implement-issue worktree
  # does not install a timer that dies with the worktree.
  repo="$(bash "$KIT/scripts/main-worktree.sh")"
  [ -n "$repo" ] || { echo "session-retro: bare repository, nothing to schedule" >&2; return 1; }

  mkdir -p "$UNITS"
  cat >"$UNITS/$UNIT.service" <<EOF
[Unit]
Description=ai-migration-kit — harvest the kit's own failure signals from past transcripts

[Service]
Type=oneshot
ExecStart=$repo/scripts/session-retro.sh run
EOF
  cat >"$UNITS/$UNIT.timer" <<EOF
[Unit]
Description=Weekly kit session retro

[Timer]
OnCalendar=Mon *-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer"
  systemctl --user list-timers "$UNIT.timer" --no-pager
}

cmd_uninstall() {
  systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
  rm -f "$UNITS/$UNIT.service" "$UNITS/$UNIT.timer"
  systemctl --user daemon-reload
  echo "session-retro: timer removed"
}

case "${1:-}" in
  run)       cmd_run ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: session-retro.sh run|install|uninstall" >&2; exit 2 ;;
esac
