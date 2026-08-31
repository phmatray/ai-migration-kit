#!/usr/bin/env bash
# Golden test for the git write-gate — the PreToolUse/Bash hook that routes the three guarded writes
# through the guards and refuses the discards that produced #26 and #280.
#
# Written fail-path-first, the tests/roseline/test.sh shape: a gate whose PASS path is the only one
# exercised proves nothing, and a gate that fails CLOSED anywhere would deadlock every repository
# the plugin is installed in but never used with (ADR 0002). So every case drives the real script
# over a synthetic PreToolUse payload — that payload is the gate's entire input contract — and the
# allow half of the matrix is as long as the deny half on purpose.
#
# NOTHING here runs a destructive git command. The deny cases are payload strings; the scratch
# repositories exist only so the profile probe has something real to answer about.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
kit_guard kit_guard_samples_unchanged

GATE="$KIT/hooks/git-write-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# The scratch repositories the probe answers about. mktemp -d, NOT a counter: `n=$((n+1))` inside a
# $(...) helper increments a subshell's copy and every "fresh" repo would be the same directory —
# the trap tests/_lib.sh documents and tests/roseline/test.sh already tripped over.
#
# `git init` only; nothing is ever committed and no working tree is ever mutated. The probe reads
# `rev-parse --show-toplevel` plus one `[ -f ]`, which is all these fixtures have to satisfy.
profile_repo() {
  local d; d=$(mktemp -d "$WORK/prof.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  mkdir -p "$d/.claude/skills"
  : > "$d/.claude/skills/repo-profile.md"
  printf '%s' "$d"
}
plain_repo() {
  local d; d=$(mktemp -d "$WORK/plain.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  : > "$d/README.md"
  printf '%s' "$d"
}

# A PATH holding exactly what the gate shells out to, plus whichever stubs are named — built by
# NAMING the tools rather than by subtracting one from $PATH, so the "absent" case holds on every
# host. Every extra argument becomes an empty executable.
shim_path() { # $1 destination dir; $2… stub names
  local d="$1" c p; shift
  mkdir -p "$d"
  for c in bash cat jq awk git tr printf sed; do
    p=$(command -v "$c" 2>/dev/null) || continue
    ln -s "$p" "$d/$c" 2>/dev/null || true
  done
  for c in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"; done
  printf '%s' "$d"
}

pay() { # $1 tool  $2 command  $3 cwd
  jq -nc --arg t "$1" --arg c "$2" --arg d "$3" \
    '{session_id:"gitgate", cwd:$d, tool_name:$t, tool_input:{command:$c}}'
}

# Drives the gate with a synthetic payload. Asserts the exit status, the decision, and — when
# denying — that the reason names the replacement.
# $1 name  $2 expected ("deny"|"pass")  $3 substring the reason must contain  $4 payload
# $5 optional PATH  $6 optional GIT_GATE value
verdict() {
  local name="$1" want="$2" want_msg="$3" payload="$4" gate_path="${5:-$PATH}" sw="${6:-}"
  local out decision rc=0
  if [ -n "$sw" ]; then
    out=$(printf '%s' "$payload" | env PATH="$gate_path" GIT_GATE="$sw" bash "$GATE" 2>/dev/null) || rc=$?
  else
    out=$(printf '%s' "$payload" | env PATH="$gate_path" bash "$GATE" 2>/dev/null) || rc=$?
  fi
  # Exit status is half the PreToolUse contract — a non-zero exit blocks the tool regardless of
  # stdout, so a regression that turned a fail-open path into `exit 2` would be scored "pass" here
  # while blocking every Bash call in production. Matt's script is exactly that shape (`exit 2`).
  [ "$rc" -eq 0 ] || { echo "FAIL [$name]: gate exited $rc; its contract is always exit 0"; exit 1; }
  if [ -z "$out" ]; then decision="pass"; else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed)
  fi
  if [ "$decision" != "$want" ]; then
    echo "FAIL [$name]: expected $want, got $decision"; echo "$out"; exit 1
  fi
  if [ -n "$want_msg" ]; then
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' \
      | grep -qF -e "$want_msg" || { echo "FAIL [$name]: reason lacks '$want_msg'"; echo "$out"; exit 1; }
      # `-e`, not a bare argument: half the replacements this suite asserts start with `--`
      # (`--force-with-lease`), and grep would read those as its own options.
  fi
  echo "ok: $name -> $decision"
}

PROF=$(profile_repo); PLAIN=$(plain_repo)
[ "$PROF" != "$PLAIN" ] || { echo "FAIL: fixture helpers returned the same directory"; exit 1; }

# ------------------------------------------------------- 1. the deny rows, in a profiled repo (D)
verdict "D1  checkout <ref> -- ."      deny "checkout -- <path>" "$(pay Bash 'git checkout main -- .' "$PROF")"
verdict "D2  checkout ."               deny "checkout -- <path>" "$(pay Bash 'git checkout .' "$PROF")"
verdict "D3  restore --staged ."       deny "git restore <path>" "$(pay Bash 'git restore --staged .' "$PROF")"
verdict "D4  reset --hard"             deny "git reset --keep"   "$(pay Bash 'git reset --hard HEAD~1' "$PROF")"
verdict "D5  clean -fd"                deny "git clean -n"       "$(pay Bash 'git clean -fd' "$PROF")"
verdict "D6  push --force"             deny "--force-with-lease" "$(pay Bash 'git push --force origin main' "$PROF")"
verdict "D7  bare commit"              deny "guarded-commit.sh"  "$(pay Bash 'git commit -m wip' "$PROF")"
verdict "D8  bare push"                deny "guarded-push.sh"    "$(pay Bash 'git push' "$PROF")"
verdict "D9  -c option skipping"       deny "guarded-commit.sh" \
  "$(pay Bash 'git -c user.email=x -c user.name=y commit -m x' "$PROF")"
verdict "D10 the write is segment 2"   deny "git reset --keep"   "$(pay Bash 'cd sub && git reset --hard' "$PROF")"
# The `-C` path names the repository the command acts on, so it outranks the payload's cwd: a push
# into a profiled repo is that repo's push no matter where the shell happens to be standing.
verdict "D11 -C path outranks cwd"     deny "guarded-push.sh"    "$(pay Bash "git -C $PROF push" "$PLAIN")"
verdict "D12 bare merge"               deny "guarded-merge.sh"   "$(pay Bash 'git merge origin/main' "$PROF")"
verdict "D13 clean --force"            deny "git clean -n"       "$(pay Bash 'git clean --force -d' "$PROF")"
verdict "D14 push -f"                  deny "--force-with-lease" "$(pay Bash 'git push -f' "$PROF")"

# ---------------------------------------------------------------- 6. structural wiring (S)
# S1 — hooks are outside parse-sweep's default target set (docs/backlog.md records that gap), so the
# sweep is invoked on this file explicitly. bash 3.2 is the floor the sweep enforces.
./scripts/parse-sweep.sh hooks/git-write-gate.sh tests/git-gate/test.sh >/dev/null \
  || { echo "FAIL: parse-sweep rejects the gate or this suite"; exit 1; }
echo "ok: the gate and this suite pass ./scripts/parse-sweep.sh"

echo "git write-gate golden test OK"
