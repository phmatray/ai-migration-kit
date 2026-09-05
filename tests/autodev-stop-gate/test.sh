#!/usr/bin/env bash
# Golden test for the auto-dev Stop gate — #417's answer to "auto-dev's never-wait invariant is a
# grep over prompt wording": a `Stop` hook that refuses the stop only on POSITIVE evidence that an
# auto-dev fleet in THIS repository has undrained work (the pinned state file, #417 Task 2), never
# on the wording of anything a model said.
#
# Written fail-path-first, the tests/git-gate/test.sh and tests/roseline/test.sh shape: a gate whose
# PASS (fail-open) path is the only one exercised proves nothing, and ADR 0002 (inherited here
# verbatim — every hook this plugin ships fails open) means the fail-open half has to be at least as
# thorough as the refusal half. Every case drives the REAL script over a synthetic Stop payload on
# stdin plus env vars — that is the hook's entire input contract.
#
# NOTHING here touches this session's own hooks or a real state file — every fixture is a scratch git
# repo (a real `origin` remote so the hook's owner/repo derivation has something to parse) plus a
# scratch AUTODEV_STATE_DIR the hook is pointed at via env, never the real
# $XDG_STATE_HOME/$HOME/.local/state a live fleet would use.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
kit_guard kit_guard_samples_unchanged

GATE="$KIT/hooks/autodev-stop-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# A scratch repo with a real `origin` remote, so the hook's owner/repo derivation has something to
# read. `git init` only; nothing is ever committed.
repo_with_remote() { # $1 remote URL
  local d; d=$(mktemp -d "$WORK/repo.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  git -C "$d" remote add origin "$1" >/dev/null 2>&1
  printf '%s' "$d"
}
repo_no_remote() {
  local d; d=$(mktemp -d "$WORK/norigin.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  printf '%s' "$d"
}

# The exact path the hook is specified to derive:
# ${AUTODEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/ai-migration-kit/auto-dev-<owner>-<repo>.md
state_path() { # $1 AUTODEV_STATE_DIR base  $2 owner  $3 repo
  printf '%s/ai-migration-kit/auto-dev-%s-%s.md' "$1" "$2" "$3"
}

pay() { # $1 cwd  $2 stop_hook_active (true|false)  $3 optional session_id
  jq -nc --arg d "$1" --argjson a "$2" --arg s "${3:-gate-test}" \
    '{session_id:$s, cwd:$d, hook_event_name:"Stop", stop_hook_active:$a}'
}

# Drives the gate with a synthetic payload + env. Asserts exit code and (for a refusal) that the
# stderr names the given substrings.
# $1 name  $2 want_rc (0|2)  $3 payload  $4 AUTODEV_STATE_DIR  $5 AUTODEV_GATE  $6... substrings stderr must contain
verdict() {
  local name="$1" want_rc="$2" payload="$3" state_dir="$4" sw=""
  if [ "$#" -ge 5 ]; then sw="$5"; shift 5; else shift 4; fi
  local out rc=0
  out=$(printf '%s' "$payload" | env AUTODEV_STATE_DIR="$state_dir" AUTODEV_GATE="$sw" bash "$GATE" 2>&1 1>/dev/null) || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL [$name]: expected exit $want_rc, got $rc"; echo "$out"; exit 1
  fi
  if [ "$want_rc" = 0 ] && [ -n "$out" ]; then
    echo "FAIL [$name]: fail-open path printed output — must be silent: $out"; exit 1
  fi
  local sub
  for sub in "$@"; do
    grep -qF -- "$sub" <<<"$out" || { echo "FAIL [$name]: stderr lacks '$sub' — got: $out"; exit 1; }
  done
  echo "ok: $name -> exit $rc"
}

REPO=$(repo_with_remote "https://github.com/acme/widgets.git")
NOREMOTE=$(repo_no_remote)
SDIR=$(mktemp -d "$WORK/state.XXXXXX")
SPATH=$(state_path "$SDIR" acme widgets)
mkdir -p "$(dirname "$SPATH")"

write_state() { # $1 in-flight body  $2 queue body
  cat > "$SPATH" <<EOF
# auto-dev state — acme/widgets, N=3 · merges: 1
## In flight
$1
## Queue — SMALL (then MEDIUM), eligible & area-tagged
$2
## Completed
EOF
}

# --------------------------------------------------------------- 1. no state file at all (AC1)
rm -f "$SPATH"
verdict "AC1 no state file"          0 "$(pay "$REPO" false)" "$SDIR"

# ------------------------------------------------------- 2. state file, both sections empty (AC2)
write_state "" ""
verdict "AC2 empty in-flight and queue" 0 "$(pay "$REPO" false)" "$SDIR"

# --------------------------------------------------- 3. one in-flight slot -> REFUSE (AC3)
write_state "- Slot A → #123 (auto-dev) — implementing" ""
verdict "AC3 one in-flight slot refuses" 2 "$(pay "$REPO" false)" "$SDIR" "" \
  "acme/widgets" "1" "AUTODEV_GATE=off"

# ----------------------------------------------- 4. same state, AUTODEV_GATE=off -> allow (AC4)
verdict "AC4 AUTODEV_GATE=off allows"  0 "$(pay "$REPO" false)" "$SDIR" off

# ------------------------------------------- 5. same state, stop_hook_active:true -> allow (AC5)
verdict "AC5 stop_hook_active true allows" 0 "$(pay "$REPO" true)" "$SDIR"

# ------------------------------------------------- 6. same state, but STALE mtime -> allow (AC6)
# A timestamp far enough in the past that no plausible staleness bound reads it as fresh.
touch -t 202001010000 "$SPATH"
verdict "AC6 stale state file allows"  0 "$(pay "$REPO" false)" "$SDIR"
write_state "- Slot A → #123 (auto-dev) — implementing" ""  # restore a fresh copy for what follows

# --------------------------------------------------- 7. malformed payload / no jq -> allow (AC7)
verdict "AC7 payload is not JSON"      0 "not json at all" "$SDIR"

NOJQ=$(mktemp -d "$WORK/nojq.XXXXXX")
for c in bash cat awk grep git find date sed; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -s "$p" "$NOJQ/$c" 2>/dev/null || true
done
out=$(printf '%s' "$(pay "$REPO" false 2>/dev/null || echo '{}')" \
  | env PATH="$NOJQ" AUTODEV_STATE_DIR="$SDIR" AUTODEV_GATE="" bash "$GATE" 2>&1 1>/dev/null) || rc=$?
rc=${rc:-0}
[ "$rc" = 0 ] || { echo "FAIL [AC7 no jq]: expected exit 0, got $rc: $out"; exit 1; }
[ -z "$out" ] || { echo "FAIL [AC7 no jq]: expected silence, got: $out"; exit 1; }
echo "ok: AC7 no jq on PATH -> exit 0, silent"

# --------------------------------------------------------------- 8. queue-only also refuses
write_state "" "#10 (compiler), #11 (studio)"
verdict "queue-only refuses, names depth" 2 "$(pay "$REPO" false)" "$SDIR" "" "2" "AUTODEV_GATE=off"

# --------------------------------------------------------- 9. no remote / can't derive -> allow
write_state "- Slot A → #123 (auto-dev) — implementing" ""
verdict "no origin remote allows (nothing to derive)" 0 "$(pay "$NOREMOTE" false)" "$SDIR"

# --------------------------------------------------------------- 10. a repo with no cwd at all
verdict "empty cwd allows" 0 "$(jq -nc '{session_id:"x",hook_event_name:"Stop",stop_hook_active:false}')" "$SDIR"

# ------------------------------------------------------------------------- 11. structural wiring
./scripts/parse-sweep.sh hooks/autodev-stop-gate.sh tests/autodev-stop-gate/test.sh >/dev/null \
  || { echo "FAIL: parse-sweep rejects the gate or this suite"; exit 1; }
echo "ok: the gate and this suite pass ./scripts/parse-sweep.sh"

HJ="$KIT/hooks/hooks.json"
jq -e . "$HJ" >/dev/null 2>&1 || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }
n=$(jq '[.hooks.Stop[]?] | length' "$HJ")
[ "$n" = "1" ] || { echo "FAIL: hooks.json has $n Stop hook entries, want exactly 1"; exit 1; }
got=$(jq -r '.hooks.Stop[0].hooks[0].command' "$HJ")
case "$got" in
  *'${CLAUDE_PLUGIN_ROOT}'*autodev-stop-gate.sh) echo "ok: hooks.json wires Stop -> $got" ;;
  *) echo "FAIL: Stop hook command is '$got'; must reference \${CLAUDE_PLUGIN_ROOT}/hooks/autodev-stop-gate.sh"; exit 1 ;;
esac
tmo=$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$HJ")
[ -n "$tmo" ] || { echo "FAIL: the Stop hook has no timeout; a hung gate would stall every stop attempt"; exit 1; }
resolved="${got/\$\{CLAUDE_PLUGIN_ROOT\}/$KIT}"
[ -x "$resolved" ] || { echo "FAIL: hooks.json points at '$resolved', which is not an executable file"; exit 1; }
echo "ok: the registered command resolves to a shipped executable with timeout=$tmo"

# The other three hooks must survive this PR untouched.
jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Read")] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one Read matcher"; exit 1; }
jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Bash")] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one Bash matcher"; exit 1; }
jq -e '[.hooks.SessionStart[]?] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one SessionStart entry"; exit 1; }
echo "ok: the other three hooks are still registered"

# S3 — the registry entry (ADR 0011: recorded in not_decisions, never registered as a decision).
python3 - "$KIT/decisions/registry.json" <<'PY' || exit 1
import json, sys
reg = json.load(open(sys.argv[1]))
nd = reg.get("not_decisions", {})
key = "hooks/autodev-stop-gate.sh"
if key not in nd:
    print(f"FAIL: decisions/registry.json not_decisions has no entry for {key}")
    sys.exit(1)
if not nd[key].strip():
    print(f"FAIL: the not_decisions entry for {key} is empty; it must say WHY")
    sys.exit(1)
print(f"ok: decisions/registry.json records {key} under not_decisions")
PY

# S4 — the off-switch is documented somewhere a reader can find it.
grep -qF 'AUTODEV_GATE' "$KIT/README.md" \
  || { echo "FAIL: README does not document AUTODEV_GATE"; exit 1; }
echo "ok: README documents AUTODEV_GATE"

echo "autodev-stop-gate golden test OK"
