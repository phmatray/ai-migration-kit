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
else
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

echo "tick-plan golden test OK"
