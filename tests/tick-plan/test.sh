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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A `gh` stub on PATH: records every invocation, so the test can prove that a refused write
# never reached the network. It also stores the PATCHed body and serves it back on a GET, so
# the script's verify-after-write step is genuinely exercised rather than stubbed away.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
if [[ "$*" == *PATCH* ]]; then
  cat > "$GH_PAYLOAD"
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
  export GH_CALL_LOG GH_PAYLOAD GH_STORE
  : > "$GH_CALL_LOG"; rm -f "$GH_PAYLOAD" "$GH_STORE"
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
