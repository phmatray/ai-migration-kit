#!/usr/bin/env bash
# Golden test for tick-plan.sh — the guarded write that replaces
#   jq -Rs '{body: .}' plan.md | gh api .../issues/N -X PATCH --input -
#
# That pipeline wiped two live issue bodies (Koine#1813). Measured cause: `jq -Rs` on a
# missing OR empty file still emits a well-formed {"body": ""}, and `gh api` applies it
# faithfully. On the empty-file path jq even exits 0, so `set -o pipefail` alone does NOT
# catch it. Every case below must therefore fail CLOSED — refuse, exit non-zero, and make
# NO call to gh at all.
set -euo pipefail
cd "$(dirname "$0")/../.."

TICK="./skills/implement-issue/scripts/tick-plan.sh"
[ -x "$TICK" ] || { echo "FAIL: $TICK missing or not executable"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72) — eight suites each had
# their own, and they had diverged. KIT_ROOT is derived from this file's location rather
# than $PWD: $PWD is only right because a `cd` sits above, and moving it would break the
# source silently (tests/ci-wiring did exactly that).
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# A `gh` stub on PATH: records every invocation, so the test can prove that a refused write
# never reached the network. It also stores the PATCHed body and serves it back on a GET, so
# the script's verify-after-write step is genuinely exercised rather than stubbed away.
#
# The stub resolves `--input` the way real `gh` does — a path is read from that file, a bare `-`
# from stdin — and records which of the two it was in $GH_INPUT_PATH. That is what lets the suite
# pin the payload's transport (#113): `--input -` is the stdin pipe that sat for 25–35 minutes on
# a 30KB body after GitHub had already stored it.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
if [[ "$*" == *PATCH* ]]; then
  input="<none>"; prev=""
  for a in "$@"; do
    [ "$prev" = "--input" ] && input="$a"
    prev="$a"
  done
  printf '%s\n' "$input" > "$GH_INPUT_PATH"
  if [ "$input" = "<none>" ] || [ "$input" = "-" ]; then
    cat > "$GH_PAYLOAD"
  else
    cp "$input" "$GH_PAYLOAD"
  fi
  jq -r .body < "$GH_PAYLOAD" > "$GH_STORE"
  # $GH_MANGLE_STORE models a concurrent edit: GitHub ends up holding something other than
  # what was sent, which the read-back must catch whether or not the call was bounded.
  [ -n "${GH_MANGLE_STORE:-}" ] && printf 'a concurrent edit\n' >> "$GH_STORE"
  # $GH_PAYLOAD is stored BEFORE the sleep on purpose: that is the production symptom (#113) —
  # GitHub already holds the new body while the client is still waiting on the call. `exec` so
  # the sleep inherits this pid and a kill on it actually ends the call.
  [ -n "${GH_PATCH_SLEEP:-}" ] && exec sleep "$GH_PATCH_SLEEP"
  exit 0
else
  [ -n "${GH_READ_FAIL:-}" ] && exit 3
  [ -f "$GH_STORE" ] && cat "$GH_STORE"
fi
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

BEFORE="$WORK/before.md"
cat > "$BEFORE" <<'EOF'
## Summary

Body with **bold**, `backticks`, "quotes" and a stray - [ ] lookalike inline.

## 🛠️ Implementation plan

- [ ] **Task 1 — Reproduce.** Confirm the empty-body PATCH.
- [ ] **Task 2 — Fail closed.** Guard the write.
- [ ] **Task 3 — Verify.** Re-read after writing.
EOF

fresh_log() {
  GH_CALL_LOG="$WORK/gh-calls.$1.log"
  GH_PAYLOAD="$WORK/gh-payload.$1.json"
  GH_STORE="$WORK/gh-store.$1.md"
  GH_INPUT_PATH="$WORK/gh-input.$1.txt"
  export GH_CALL_LOG GH_PAYLOAD GH_STORE GH_INPUT_PATH
  : > "$GH_CALL_LOG"; rm -f "$GH_PAYLOAD" "$GH_STORE" "$GH_INPUT_PATH"
}

# Asserts: the command refused (non-zero) AND gh was never invoked.
refuses() {
  local name="$1"; shift
  fresh_log "$name"
  if "$@" >"$WORK/out.$name" 2>"$WORK/err.$name"; then
    echo "FAIL [$name]: expected a refusal, got exit 0"; cat "$WORK/out.$name"; exit 1
  fi
  if [ -s "$GH_CALL_LOG" ]; then
    echo "FAIL [$name]: refused but STILL called gh:"; cat "$GH_CALL_LOG"; exit 1
  fi
  echo "  ok: $name — refused, no gh call"
}

# ---------------------------------------------------------------- refusals

# 1. The exact production failure: the plan file was never written.
refuses missing-file "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/nope.md"

# 2. The case `set -o pipefail` does NOT catch: file exists but is empty (jq exits 0).
: > "$WORK/empty.md"
refuses empty-file "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/empty.md"

# 3. Truncated mid-write: valid prefix, silently loses the tail of the plan.
head -c 120 "$BEFORE" > "$WORK/truncated.md"
refuses truncated "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/truncated.md"

# 4. Body edited beyond the checkboxes — ticking is a one-character substitution, so any
#    other change means something rewrote the body and must not be pushed.
sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/' "$BEFORE" | sed 's/Confirm the empty-body PATCH./Rewritten by an agent./' > "$WORK/mangled.md"
refuses body-mutated "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/mangled.md"

# 5. The plan heading vanished.
grep -v '🛠️ Implementation plan' "$BEFORE" | sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/' > "$WORK/noheading.md"
refuses heading-lost "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/noheading.md"

# 6. Nothing was actually flipped — the intended edit silently didn't land.
cp "$BEFORE" "$WORK/noop.md"
refuses no-change "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/noop.md"

# 7. Un-ticking: a box went from [x] back to [ ]. Never legitimate here.
sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/; s/^- \[ \] \*\*Task 2/- [x] **Task 2/' "$BEFORE" > "$WORK/two-done.md"
sed 's/^- \[x\] \*\*Task 2/- [ ] **Task 2/' "$WORK/two-done.md" > "$WORK/unticked.md"
refuses unticking "$TICK" --repo o/r --issue 1 --before "$WORK/two-done.md" --after "$WORK/unticked.md"

# ---------------------------------------------------------------- happy path

fresh_log happy
sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/' "$BEFORE" > "$WORK/ticked.md"
"$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" > "$WORK/out.happy" 2>&1 \
  || { echo "FAIL [happy]: a legitimate tick was refused"; cat "$WORK/out.happy"; exit 1; }

grep -q 'repos/o/r/issues/42' "$GH_CALL_LOG" \
  || { echo "FAIL [happy]: wrong endpoint"; cat "$GH_CALL_LOG"; exit 1; }
grep -q 'X PATCH\|-X PATCH' "$GH_CALL_LOG" \
  || { echo "FAIL [happy]: not a PATCH"; cat "$GH_CALL_LOG"; exit 1; }

# The payload must round-trip to the ticked file byte for byte.
python3 - "$GH_PAYLOAD" "$WORK/ticked.md" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
want = open(sys.argv[2], encoding="utf-8").read()
assert set(payload) == {"body"}, f"payload should carry only 'body', got {sorted(payload)}"
assert payload["body"] == want, "payload body is not byte-identical to the ticked file"
assert payload["body"].strip(), "payload body is empty — the exact bug this guards"
PY
echo "  ok: happy — PATCHed the ticked body verbatim"

# 7b. The payload travels in a FILE, never down a stdin pipe. `--input -` is the last surviving
#     piece of the recipe this script replaced, and it is what made a 30KB PATCH take 25–35
#     minutes to return from a write GitHub had already applied (#113).
if grep -qE -- '--input -($| )' "$GH_CALL_LOG"; then
  echo "FAIL [input-file]: the PATCH still pipes its payload via '--input -'"; cat "$GH_CALL_LOG"; exit 1
fi
INPUT_PATH=$(cat "$GH_INPUT_PATH")
case "$INPUT_PATH" in
  ''|'-'|'<none>')
    echo "FAIL [input-file]: expected '--input <file>', the PATCH passed '${INPUT_PATH:-<empty>}'"
    cat "$GH_CALL_LOG"; exit 1 ;;
esac
# The stub copied $INPUT_PATH into $GH_PAYLOAD, which the round-trip check above already proved
# byte-identical to the ticked file — so the file really held the payload, not just a path.
[ -f "$GH_PAYLOAD" ] || { echo "FAIL [input-file]: no payload was captured from $INPUT_PATH"; exit 1; }
echo "  ok: input-file — the payload came from $INPUT_PATH, not a stdin pipe"

# ...and it is scratch: registered for cleanup, so it does not outlive the run.
if [ -e "$INPUT_PATH" ]; then
  echo "FAIL [input-file]: payload temp file $INPUT_PATH outlived the script"; exit 1
fi
echo "  ok: input-file — the payload temp file is removed on exit"

# 8. A comment-hosted plan targets the comments endpoint, not the issue.
fresh_log comment
"$TICK" --repo o/r --issue 42 --comment-id 998877 --before "$BEFORE" --after "$WORK/ticked.md" >/dev/null 2>&1 \
  || { echo "FAIL [comment]: legitimate comment tick refused"; exit 1; }
grep -q 'repos/o/r/issues/comments/998877' "$GH_CALL_LOG" \
  || { echo "FAIL [comment]: wrong endpoint"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: comment — PATCHed the comment endpoint"

# 9. Runs from a foreign working directory (plugin-install simulation, cf. ci.yml).
fresh_log foreign
KIT="$PWD"
( cd "$WORK" && bash "$KIT/$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" >/dev/null 2>&1 ) \
  || { echo "FAIL [foreign-cwd]: refused when run from another directory"; exit 1; }
echo "  ok: foreign cwd"

# ---------------------------------------------------------------- the deadline
#
# The PATCH runs under a pure-bash deadline (TICK_PLAN_PATCH_TIMEOUT, default 60s; no timeout(1),
# which stock macOS does not ship). Expiry is NOT failure: killing the call does not un-send it,
# so the read-back — which costs 0.4s against the real API — is what decides the verdict.

# Runs the tick with a stub that sleeps past the deadline; leaves the exit code in $RC and the
# wall-clock cost in $ELAPSED. No command substitution around the call: an orphaned child would
# hold the pipe open and hide the very stall being measured.
run_bounded() {
  local name="$1"; shift
  fresh_log "$name"
  local start; start=$(date +%s)
  RC=0
  TICK_PLAN_PATCH_TIMEOUT=1 "$@" > "$WORK/out.$name" 2>&1 || RC=$?
  ELAPSED=$(( $(date +%s) - start ))
}

export GH_PATCH_SLEEP=6

# 10. Bounded, and GitHub holds what was sent → success, and back in a couple of seconds rather
#     than at the end of the sleep.
run_bounded bounded-match "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
[ "$RC" -eq 0 ] || { echo "FAIL [bounded-match]: expected success from the read-back, got exit $RC"
                     cat "$WORK/out.bounded-match"; exit 1; }
[ "$ELAPSED" -lt 5 ] || { echo "FAIL [bounded-match]: took ${ELAPSED}s — the PATCH was not bounded"
                          cat "$WORK/out.bounded-match"; exit 1; }
grep -q 'body verified intact' "$WORK/out.bounded-match" \
  || { echo "FAIL [bounded-match]: no verified-intact verdict"; cat "$WORK/out.bounded-match"; exit 1; }
grep -qi 'bounded' "$WORK/out.bounded-match" \
  || { echo "FAIL [bounded-match]: the output does not say the call was bounded, so a reader cannot
        tell the two success paths apart"; cat "$WORK/out.bounded-match"; exit 1; }
echo "  ok: bounded-match — bounded at 1s, verdict from the read-back (${ELAPSED}s, sleep was 6s)"

# 11. Bounded, but GitHub holds something else → the existing ALERT, exit 1. A killed call must
#     never be allowed to launder a mismatch into success.
export GH_MANGLE_STORE=1
run_bounded bounded-differs "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_MANGLE_STORE
[ "$RC" -eq 1 ] || { echo "FAIL [bounded-differs]: expected exit 1, got $RC"
                     cat "$WORK/out.bounded-differs"; exit 1; }
grep -q 'ALERT' "$WORK/out.bounded-differs" \
  || { echo "FAIL [bounded-differs]: no ALERT on a mismatched body"; cat "$WORK/out.bounded-differs"; exit 1; }
[ "$ELAPSED" -lt 5 ] || { echo "FAIL [bounded-differs]: took ${ELAPSED}s — the PATCH was not bounded"; exit 1; }
echo "  ok: bounded-differs — bounded, mismatch still ALERTs and exits 1"

# 12. Bounded AND the read-back failed → nothing at all confirms what GitHub holds, so the script
#     must not report success. This is the one path where the sole authority is unavailable.
export GH_READ_FAIL=1
run_bounded bounded-unverified "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_READ_FAIL
[ "$RC" -ne 0 ] || { echo "FAIL [bounded-unverified]: claimed success with no evidence either way"
                     cat "$WORK/out.bounded-unverified"; exit 1; }
grep -q 'ALERT' "$WORK/out.bounded-unverified" \
  || { echo "FAIL [bounded-unverified]: no ALERT"; cat "$WORK/out.bounded-unverified"; exit 1; }
echo "  ok: bounded-unverified — bounded + unreadable = no verdict, and it says so"

unset GH_PATCH_SLEEP

# 13. Unbounded PATCH whose read-back fails keeps today's softer contract: gh itself reported
#     success, so this stays a WARNING and exit 0 rather than becoming an error.
fresh_log warn-unverified
export GH_READ_FAIL=1
RC=0
"$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.warn-unverified" 2>&1 || RC=$?
unset GH_READ_FAIL
[ "$RC" -eq 0 ] || { echo "FAIL [warn-unverified]: a successful PATCH must not fail on a read-back hiccup"
                     cat "$WORK/out.warn-unverified"; exit 1; }
grep -q 'WARNING' "$WORK/out.warn-unverified" \
  || { echo "FAIL [warn-unverified]: no WARNING"; cat "$WORK/out.warn-unverified"; exit 1; }
echo "  ok: warn-unverified — unbounded + unreadable stays a WARNING"

# 14. The deadline must be a sane number: a junk value is caught before anything is sent.
refuses bad-timeout env TICK_PLAN_PATCH_TIMEOUT=soon \
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"

echo "tick-plan golden test OK"
