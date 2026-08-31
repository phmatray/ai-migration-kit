#!/usr/bin/env bash
# Golden test for skills/merge-pr/scripts/parent-decision-note.sh (#365).
#
# When `merge-pr` squash-merges a decomposed child's PR, this script is the only thing that keeps
# the tracking parent's `## Decisions so far` section current — the overwhelming majority of merges
# aren't part of a decomposition (#315) at all, so the common case has to be a true no-op, and a
# re-run on an already-merged PR (`merge-pr` is resume-safe) must not duplicate the line it already
# wrote. The suite stubs `gh` (never a real issue, per this kit's testing rule — see
# skills/_shared/test-seams.md and the fixture/stub-only instruction this issue was worked under)
# and keeps a scratch FILE standing in for "the parent issue's body on GitHub", updated by the
# script's own `gh issue edit --body-file -` call and read back by the next `gh issue view`, so the
# suite exercises the real read-modify-write-readback cycle rather than a canned response per call.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

SCRIPT="$KIT_ROOT/skills/merge-pr/scripts/parent-decision-note.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing or not executable"; exit 1; }

command -v jq > /dev/null 2>&1 || { echo "FAIL: jq is missing"; exit 1; }

WORK=$(kit_scratch)
mkdir -p "$WORK/bin"
STATE_BODY="$WORK/state-body.txt"

# ------------------------------------------------------------------------------------ the gh stub
#
# Routed on the NOUN/VERB and, for `issue view`, the requested --json fields — never on the issue
# number — because the script queries the CHILD (`--json parent`) and the PARENT (`--json body`)
# through the identically-shaped `gh issue view <n> -R <repo> --json <fields>` call.
#
#   GH_PARENT_JSON          raw JSON for `gh issue view <child> --json parent`  default {"parent":null}
#   GH_PARENT_MALFORMED=1   that call answers with non-JSON garbage instead
#   GH_PARENT_VIEW_STATUS   non-zero to make the parent-lookup call itself fail (gh exit code)
#   GH_BODY_VIEW_STATUS     non-zero to make every `--json body` read fail
#   GH_PR_JSON              raw JSON for `gh pr view <pr> --json title,url`     default {}
#   GH_PR_VIEW_STATUS       non-zero to make the PR lookup fail
#   GH_ISSUE_EDIT_STATUS    non-zero to make `gh issue edit --body-file -` fail
#
# `$STATE_BODY` is the fake GitHub: seeded by the test before each run, read by every
# `--json body` view, and overwritten by `gh issue edit`'s stdin. That is what lets the
# idempotent-rerun and second-child cases assert against what the FIRST call actually produced,
# not a hand-written expectation of it.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"

noun="${1:-}"; shift || true
case "$noun" in
  issue)
    verb="${1:-}"; shift || true
    case "$verb" in
      view)
        shift || true   # the issue number — routing never keys on it, see the header above
        fields=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --json) fields="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$fields" in
          parent)
            [ "${GH_PARENT_VIEW_STATUS:-0}" = 0 ] || { echo "gh: simulated failure" >&2; exit "$GH_PARENT_VIEW_STATUS"; }
            if [ "${GH_PARENT_MALFORMED:-0}" = 1 ]; then
              echo 'not-json-at-all {{{'
              exit 0
            fi
            printf '%s\n' "${GH_PARENT_JSON:-NULL_PARENT}" | sed 's/^NULL_PARENT$/{"parent":null}/'
            exit 0 ;;
          body)
            [ "${GH_BODY_VIEW_STATUS:-0}" = 0 ] || { echo "gh: simulated failure" >&2; exit "$GH_BODY_VIEW_STATUS"; }
            body=$(cat "$STATE_BODY" 2>/dev/null || true)
            jq -n --arg b "$body" '{body: $b}'
            exit 0 ;;
          *) echo "unexpected --json fields for issue view: '$fields'" >&2; exit 99 ;;
        esac ;;
      edit)
        shift || true   # the issue number
        while [ $# -gt 0 ]; do
          case "$1" in
            --body-file) shift 2 ;;
            *) shift ;;
          esac
        done
        newbody=$(cat)
        [ "${GH_ISSUE_EDIT_STATUS:-0}" = 0 ] || { echo "gh: simulated edit failure" >&2; exit "$GH_ISSUE_EDIT_STATUS"; }
        printf '%s' "$newbody" > "$STATE_BODY"
        exit 0 ;;
      *) echo "unexpected issue verb: $verb" >&2; exit 99 ;;
    esac ;;
  pr)
    verb="${1:-}"; shift || true
    case "$verb" in
      view)
        [ "${GH_PR_VIEW_STATUS:-0}" = 0 ] || { echo "gh: simulated failure" >&2; exit "$GH_PR_VIEW_STATUS"; }
        printf '%s\n' "${GH_PR_JSON:-EMPTY_PR}" | sed 's/^EMPTY_PR$/{}/'
        exit 0 ;;
      *) echo "unexpected pr verb: $verb" >&2; exit 99 ;;
    esac ;;
  *) echo "unexpected gh invocation: $noun $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export STATE_BODY

fails=0
case_n=0

run_case() {   # run_case <label> <child> <pr> <repo>
  local label="$1" child="$2" pr="$3" repo="$4"
  case_n=$((case_n + 1))
  GH_CALL_LOG="$WORK/calls.$case_n.log"; export GH_CALL_LOG
  : > "$GH_CALL_LOG"
  OUT="$WORK/out.$case_n"; ERR="$WORK/err.$case_n"
  set +e
  "$SCRIPT" "$child" "$pr" "$repo" > "$OUT" 2> "$ERR"
  RC=$?
  set -e
  CASE="$label"
}

expect_rc() {
  if [ "$RC" -ne "$1" ]; then
    echo "FAIL: [$CASE] expected exit $1, got $RC"; echo "--- stdout"; cat "$OUT"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_stdout() {
  if [ "$(cat "$OUT")" != "$1" ]; then
    echo "FAIL: [$CASE] expected stdout '$1', got '$(cat "$OUT")'"
    fails=$((fails + 1)); return 1
  fi
}
expect_stderr_contains() {
  if ! grep -qF -- "$1" "$ERR"; then
    echo "FAIL: [$CASE] stderr lacks: $1"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_no_calls() {
  if [ -s "$GH_CALL_LOG" ]; then
    echo "FAIL: [$CASE] gh was called, and must not have been:"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
expect_body_contains() {
  if ! grep -qF -- "$1" "$STATE_BODY"; then
    echo "FAIL: [$CASE] the parent body lacks: $1"; echo "--- body"; cat "$STATE_BODY"
    fails=$((fails + 1)); return 1
  fi
}
expect_body_count() {   # expect_body_count <needle> <n>
  local got
  got=$(grep -cF -- "$1" "$STATE_BODY" || true)
  if [ "$got" != "$2" ]; then
    echo "FAIL: [$CASE] expected '$1' to appear $2 time(s) in the parent body, got $got"
    echo "--- body"; cat "$STATE_BODY"
    fails=$((fails + 1)); return 1
  fi
}
ok() { echo "ok   [$CASE] $1"; }

REPO="o/r"

# --------------------------------------------------------------------- 1. no parent: pure no-op
GH_PARENT_JSON='{"parent":null}' \
  run_case "no-parent" 42 99 "$REPO"
expect_rc 0 && expect_stdout "no-parent" \
  && ok "a child with no parent is a no-op, exit 0, prints 'no-parent'"
if grep -qE 'ARGS: pr view|ARGS: issue edit' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a PR lookup or issue edit happened despite no parent"; fails=$((fails + 1))
else
  ok "no PR lookup and no write when there is no parent — the common path stays cheap"
fi

# ---------------------------------------------------------- 2. first child appends the section
printf '## Destination\n\nShip the epic.\n\n## Notes\n\nSome notes.\n' > "$STATE_BODY"
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"feat(x): first slice (#42) (#76)","url":"https://github.com/o/r/pull/76"}' \
  run_case "first-child-appends-section" 42 76 "$REPO"
expect_rc 0 \
  && expect_stdout "appended #42's PR #76 to parent #100's Decisions so far" \
  && expect_body_contains "## Decisions so far" \
  && expect_body_contains "- #42 — feat(x): first slice ([#76](https://github.com/o/r/pull/76))" \
  && ok "no existing section: the heading and the first line are both added"

# --------------------------------------- 3. second child appends a line, not a second section
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"fix(y): second slice (#55) (#88)","url":"https://github.com/o/r/pull/88"}' \
  run_case "second-child-appends-line" 55 88 "$REPO"
expect_rc 0 \
  && expect_body_contains "- #55 — fix(y): second slice ([#88](https://github.com/o/r/pull/88))" \
  && expect_body_contains "- #42 — feat(x): first slice ([#76](https://github.com/o/r/pull/76))" \
  && expect_body_count "## Decisions so far" 1 \
  && ok "a second landed child adds a second line under the SAME heading, not a new section"

# --------------------------------------------------------------- 4. idempotent re-run: no-op
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"feat(x): first slice (#42) (#76)","url":"https://github.com/o/r/pull/76"}' \
  run_case "idempotent-rerun" 42 76 "$REPO"
expect_rc 0 && expect_stdout "already-noted" \
  && expect_body_count "- #42 — feat(x): first slice ([#76](https://github.com/o/r/pull/76))" 1 \
  && ok "re-running on the same child+PR is idempotent — one line, not two"
if grep -qE 'ARGS: issue edit' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a write happened on an idempotent re-run"; fails=$((fails + 1))
else
  ok "the idempotent path never calls gh issue edit at all"
fi

# --------------------------------------------------------------- 5. malformed parent JSON refuses
GH_PARENT_MALFORMED=1 run_case "malformed-parent-json" 42 76 "$REPO"
expect_rc 1 && expect_stderr_contains "parent-decision-note:" \
  && ok "unparseable JSON from the parent-lookup call is a refusal, not a silent no-parent"
if grep -qE 'ARGS: issue edit' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a write happened despite malformed input"; fails=$((fails + 1))
else
  ok "nothing was written after a malformed parent-lookup response"
fi

# --------------------------------------------------------------------------- 6. usage errors
case_n=$((case_n + 1))
GH_CALL_LOG="$WORK/calls.$case_n.log"; export GH_CALL_LOG
: > "$GH_CALL_LOG"
OUT="$WORK/out.$case_n"; ERR="$WORK/err.$case_n"
set +e
"$SCRIPT" 42 "$REPO" > "$OUT" 2> "$ERR"   # only 2 positional args — the 3rd (repo) is missing
RC=$?
set -e
CASE="usage-wrong-arg-count"
expect_rc 2 && expect_no_calls && ok "2 arguments instead of 3 is exit 2 and calls gh not at all"

run_case "usage-non-numeric-child" abc 76 "$REPO"
expect_rc 2 && expect_no_calls && ok "a non-numeric child issue number is exit 2, calls nothing"

run_case "usage-non-numeric-pr" 42 abc "$REPO"
expect_rc 2 && expect_no_calls && ok "a non-numeric PR number is exit 2, calls nothing"

run_case "usage-bad-repo" 42 76 "not-a-repo"
expect_rc 2 && expect_no_calls && ok "a repo not shaped like owner/repo is exit 2, calls nothing"

# ------------------------------------------------------ 7. a genuine gh failure is a real refusal
GH_PARENT_VIEW_STATUS=1 run_case "parent-lookup-gh-failure" 42 76 "$REPO"
expect_rc 1 && expect_stderr_contains "parent-decision-note:" \
  && ok "a failing parent-lookup gh call is a refusal (exit 1), never read as no-parent"

printf '## Destination\n\nShip the epic.\n' > "$STATE_BODY"
GH_PARENT_JSON='{"parent":{"number":200}}' GH_PR_VIEW_STATUS=1 \
  run_case "pr-lookup-gh-failure" 42 76 "$REPO"
expect_rc 1 && expect_stderr_contains "parent-decision-note:" \
  && ok "a failing PR lookup is a refusal, and the parent body is left untouched"
if [ "$(cat "$STATE_BODY")" != "$(printf '## Destination\n\nShip the epic.')" ]; then
  echo "FAIL: [$CASE] the parent body was mutated despite the PR lookup failing"; fails=$((fails + 1))
fi

# ----------------------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "merge-pr-parent golden test: all cases behaved as specified"
