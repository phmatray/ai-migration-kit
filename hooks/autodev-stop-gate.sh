#!/usr/bin/env bash
# auto-dev Stop gate (Claude Code Stop hook). #417.
#
# `auto-dev`'s never-wait invariant — a background worker or supervisor must never end its turn to
# wait for something it dispatched itself — used to be enforced only by
# `tests/auto-dev-never-wait/test.sh`, which greps `commands/auto-dev-worker.md` for two forbidden
# phrasings. That proves the PROMPT contains a prohibition; it cannot observe a RUN. Eleven recorded
# stalls (and five more the day this hook was written) all died at execution time, in sessions that
# suite never sees, none of them matching either forbidden phrase. This hook is the mechanism behind
# the prohibition instead of a denylist of wordings: it refuses a `Stop` event only on POSITIVE
# evidence — the fleet's own pinned state file (skills/auto-dev/SKILL.md Step 2, #417 Task 2) — that
# an auto-dev fleet in THIS repository still has undrained work.
#
# It fails OPEN, always — the decision recorded in
# docs/adr/0002-the-roseline-gate-fails-open-always.md, which applies here verbatim (its argument is
# explicitly general: "a third hook takes the same terms; it does not get a second record"). This is
# the kit's FIRST hook that can block a USER action rather than a model one, and the plugin installs
# into every repository the user opens — so its positive evidence has to be narrow and repo-scoped:
# every path that is not "an auto-dev fleet has undrained work, here, now" exits 0 with no output.
# `AUTODEV_GATE=off` (also `0|false|no|disabled`) is the off-switch, in the same position
# `ROSELINE_GATE`/`GIT_GATE` occupy in the other two hooks — checked FIRST, same reason: a stale
# override in a shell rc must never fight the value a user just typed. There is no `=on` counterpart:
# unlike the other two gates, there is no probe here for a declaration to override — the state file
# itself is the only evidence, and there's nothing to force past.
#
# Per ADR 0011, this hook is RECORDED in decisions/registry.json's `not_decisions` map — it is a
# fixed, mechanical gate with no branch a human would call a "decision" — never registered as one.
#
# ------------------------------------------------------------------ the loop-breaker (stop_hook_active)
# A `Stop` hook that refuses a stop causes Claude Code to retry the turn; on that retry the payload
# carries `stop_hook_active: true`, and honouring it here is what stops a refusal from looping
# forever — verified live against the harness before this script was written (issue #417 Task 1: a
# throwaway probe hook confirmed both the field and the exit-2-refuses contract empirically).
case "${AUTODEV_GATE:-}" in off|0|false|no|disabled) exit 0 ;; esac

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0
command -v find >/dev/null 2>&1 || exit 0

active=$(jq -r '.stop_hook_active // false' <<<"$payload" 2>/dev/null) || exit 0
[ "$active" = "true" ] && exit 0

cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

# ---------------------------------------------------------------- which repository is this?
# The state file is keyed by owner/repo, not by worktree path, so every worktree of the same
# repository resolves to the SAME file (skills/auto-dev/SKILL.md Step 2). A repo with no `origin`
# remote, or no git at all at this cwd, gives the hook nothing to key the file on — fail open.
remote_url=$(git -C "$cwd" remote get-url origin 2>/dev/null) || exit 0
[ -n "$remote_url" ] || exit 0
# Strip a trailing `.git`, then take the last two `/`- or `:`-separated segments — matches
# `https://host/owner/repo(.git)`, `git@host:owner/repo(.git)` and `ssh://git@host/owner/repo(.git)`.
owner_repo=$(printf '%s' "$remote_url" | sed -E 's#\.git$##' | sed -E 's#.*[:/]([^/:]+/[^/:]+)$#\1#')
case "$owner_repo" in */*) ;; *) exit 0 ;; esac
owner_repo_dash=$(printf '%s' "$owner_repo" | tr '/' '-')

state_base="${AUTODEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}"
state_file="$state_base/ai-migration-kit/auto-dev-${owner_repo_dash}.md"
[ -r "$state_file" ] || exit 0

# ------------------------------------------------------------------- staleness bound (24h)
# A crashed supervisor leaves the file behind forever otherwise. 24 hours is generous against a
# genuinely long-running fleet (auto-dev is meant to run hands-off, often overnight) while still
# releasing a file nobody is going to come back and clean up. `find -mmin`, not `stat`: BSD and GNU
# `stat` take incompatible flags, and this kit's own convention (hooks/roseline-gate.sh's one-shot
# marker) already uses `find … -mmin` for the same reason.
STALE_MINUTES=1440
[ -n "$(find "$state_file" -mmin -"$STALE_MINUTES" 2>/dev/null)" ] || exit 0

# --------------------------------------------------------------- read the two sections
# Between a heading and the next `## ` line (exclusive). `## Queue` is a PREFIX match — the real
# heading carries extra prose ("## Queue — SMALL (then MEDIUM), eligible & area-tagged").
section() { # $1 file  $2 heading regex (anchored at line start)
  awk -v pat="$2" '
    $0 ~ pat { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$1"
}

in_flight=$(section "$state_file" '^## In flight')
queue=$(section "$state_file" '^## Queue')

in_flight_count=$(printf '%s\n' "$in_flight" | grep -oE '#[0-9]+' | wc -l | tr -d ' ')
queue_count=$(printf '%s\n' "$queue" | grep -oE '#[0-9]+' | wc -l | tr -d ' ')

[ "$((in_flight_count + queue_count))" -gt 0 ] || exit 0

# --------------------------------------------------------------------------- refuse, naming the evidence
detail=$(printf '%s\n' "$in_flight" | grep -E '^- ' || true)
{
  echo "Blocked by the auto-dev stop gate: an auto-dev fleet has undrained work in ${owner_repo} —"
  echo "${in_flight_count} in-flight slot(s), ${queue_count} queued issue(s)."
  [ -n "$detail" ] && printf '%s\n' "$detail"
  echo "If you mean to stop anyway, set AUTODEV_GATE=off (an \`export\` inside a Bash call never"
  echo "reaches this hook — launch Claude with it set, or use it as a one-shot prefix on a command"
  echo "that stops the fleet's own supervision loop)."
} >&2
exit 2
