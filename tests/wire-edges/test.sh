#!/usr/bin/env bash
# Golden test for skills/create-issue/scripts/wire-edges.sh (#315).
#
# The script wires the edges of a decomposed issue on GitHub — each child as a sub-issue of the
# parent, each child's blockers as native `blocked_by` dependencies — and degrades to the text
# lines the bodies already carry when either feature is unavailable. What the suite pins is the
# CONTRACT the create-issue and triage-backlog skills read, at the only seam that matters: the
# script's stdout and exit code through a stubbed `gh` on PATH. Never a sourced function, never
# the id-lookup internals — see skills/_shared/test-seams.md.
#
#   one line per edge:   SUB <parent>←<child> ok|fallback|FAILED …
#                        DEP <child>⇐<blocker> ok|fallback|FAILED …
#   exit 0               every edge ok or fallback (404 = the feature is off on this host)
#   exit 1               any other non-2xx, or an issue whose database id cannot be resolved
#   exit 2               usage — the caller's arguments, not GitHub, are wrong
#   --dry-run            prints the POSTs it would send and calls gh NOT AT ALL
#
# The 404 rule is the load-bearing one: sub-issues and dependencies are GA on github.com but may
# 404 on GHES, and a run that treats that as failure leaves every decomposition half-wired with a
# red exit nobody can act on. The text `**Blocked by:**` line is always written by the skill, so
# fallback loses nothing on the body; it only loses the UI-visible frontier.
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRIPT="skills/create-issue/scripts/wire-edges.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
mkdir -p "$WORK/bin"

# ------------------------------------------------------------------------------------ the gh stub
#
# Every invocation is appended to $GH_CALL_LOG, which is how the suite proves --dry-run and a usage
# refusal call nothing. Database ids are 1000 + the issue number, so an assertion can name the id
# it expects in the POST form field and catch a script that posted the issue NUMBER instead — the
# exact mistake the real API rejects with a 404 that would then read as "feature off".
#
# Status per endpoint comes from the environment, the way real gh reports it: a non-2xx prints
# `gh: <message> (HTTP <code>)` on stderr and exits 1, with the JSON body on stdout unless --silent.
#   GH_ISSUE_STATUS   for `gh api repos/o/r/issues/N` (the id lookup)        default 200
#   GH_SUB_STATUS     for POST …/issues/P/sub_issues                        default 201
#   GH_DEP_STATUS     for POST …/issues/C/dependencies/blocked_by           default 201
#   GH_422_MESSAGE    the message a 422 carries                              default "Validation Failed"
#   GH_ISSUE_404_FOR  one issue NUMBER whose id lookup alone answers 404 (the others succeed)
#   GH_PLAIN_ERROR    when set, a non-2xx prints the bare `gh: HTTP <code>` form real gh uses
#                     when the error body is not JSON (a proxy's HTML page), with no message
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
method=GET; endpoint=""; prev=""
for a in "$@"; do
  case "$prev" in
    --method|-X) method="$a" ;;
  esac
  case "$a" in
    repos/*) endpoint="$a" ;;
  esac
  prev="$a"
done
fail() {
  local code="$1" msg
  case "$code" in
    404) msg="Not Found" ;;
    422) msg="${GH_422_MESSAGE:-Validation Failed}" ;;
    *)   msg="Server Error" ;;
  esac
  if [ -n "${GH_PLAIN_ERROR:-}" ]; then
    echo "gh: HTTP $code" >&2
    exit 1
  fi
  printf '{"message":"%s","status":"%s"}' "$msg" "$code"
  echo "gh: $msg (HTTP $code)" >&2
  exit 1
}
if [ "$method" = POST ]; then
  case "$endpoint" in
    */sub_issues)             s="${GH_SUB_STATUS:-201}" ;;
    */dependencies/blocked_by) s="${GH_DEP_STATUS:-201}" ;;
    *) echo "unexpected POST endpoint: $endpoint" >&2; exit 99 ;;
  esac
  case "$s" in 2??) exit 0 ;; *) fail "$s" ;; esac
fi
case "$endpoint" in
  repos/*/issues/[0-9]*)
    s="${GH_ISSUE_STATUS:-200}"
    n="${endpoint##*/issues/}"
    [ "${GH_ISSUE_404_FOR:-}" = "$n" ] && s=404
    case "$s" in 2??) ;; *) fail "$s" ;; esac
    echo $((1000 + n))
    exit 0 ;;
esac
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

fails=0
case_n=0

# run_case <label> → runs the script with the remaining args; leaves $OUT, $ERR, $RC, $GH_CALL_LOG
run_case() {
  local label="$1"; shift
  case_n=$((case_n + 1))
  GH_CALL_LOG="$WORK/calls.$case_n.log"; export GH_CALL_LOG
  : > "$GH_CALL_LOG"
  OUT="$WORK/out.$case_n"; ERR="$WORK/err.$case_n"
  set +e
  "$SCRIPT" "$@" > "$OUT" 2> "$ERR"
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
expect_line() {   # a stdout line matching the regex must exist
  if ! grep -qE "$1" "$OUT"; then
    echo "FAIL: [$CASE] stdout lacks a line matching /$1/"; echo "--- stdout"; cat "$OUT"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_no_line() {
  if grep -qE "$1" "$OUT"; then
    echo "FAIL: [$CASE] stdout has a line matching /$1/ that must not be there"; echo "--- stdout"; cat "$OUT"
    fails=$((fails + 1)); return 1
  fi
}
expect_call() {   # a recorded gh invocation matching the regex must exist
  if ! grep -qE "$1" "$GH_CALL_LOG"; then
    echo "FAIL: [$CASE] no gh call matching /$1/"; echo "--- calls"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
expect_no_calls() {
  if [ -s "$GH_CALL_LOG" ]; then
    echo "FAIL: [$CASE] gh was called, and must not have been:"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
ok() { echo "ok   [$CASE] $1"; }

# ----------------------------------------------------------------- 1. every endpoint answers 2xx
run_case "all-2xx" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11 --child 13:blocked-by=11,12
expect_rc 0 \
  && expect_line '^SUB 10←11 ok' && expect_line '^SUB 10←12 ok' && expect_line '^SUB 10←13 ok' \
  && expect_line '^DEP 12⇐11 ok' && expect_line '^DEP 13⇐11 ok' && expect_line '^DEP 13⇐12 ok' \
  && expect_no_line '^(SUB|DEP) .* (fallback|FAILED)' \
  && ok "three sub-issue edges and three blocked_by edges, all ok, exit 0"

# The POSTs carry DATABASE ids (1000+n), the github+json Accept header, and go to the right issue:
# the sub-issue is posted ON THE PARENT, the dependency ON THE CHILD.
expect_call 'POST.*repos/o/r/issues/10/sub_issues.*sub_issue_id=1011' \
  && expect_call 'POST.*repos/o/r/issues/13/dependencies/blocked_by.*issue_id=1012' \
  && expect_call 'Accept: application/vnd.github\+json' \
  && ok "POSTs name the parent/child endpoints with database ids, not issue numbers"

# A dependency is never posted the wrong way round (blocker's endpoint with the child's id).
if grep -qE 'POST.*issues/11/dependencies/blocked_by' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a blocked_by was posted on the BLOCKER (#11), which has no blockers"; fails=$((fails + 1))
else
  ok "no edge posted on an issue that has no blockers"
fi

# An id is looked up once per issue, not once per edge — four issues, four lookups.
lookups=$(grep -cE 'ARGS: api .*repos/o/r/issues/[0-9]+ ' "$GH_CALL_LOG" || true)
if [ "$lookups" -ne 4 ]; then
  echo "FAIL: [$CASE] expected 4 id lookups (one per issue), counted $lookups"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
else
  ok "each issue's database id is resolved exactly once"
fi

# ----------------------------------------------------- 2. sub-issues endpoint is off (404) → fallback
GH_SUB_STATUS=404 run_case "sub-issues-404" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 \
  && expect_line '^SUB 10←11 fallback' && expect_line '^SUB 10←12 fallback' \
  && expect_line '^DEP 12⇐11 ok' \
  && ok "404 on sub_issues prints fallback, dependencies still wire, exit 0"

# ------------------------------------------------- 3. dependencies endpoint is off (404) → fallback
GH_DEP_STATUS=404 run_case "dependencies-404" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 \
  && expect_line '^SUB 10←11 ok' && expect_line '^SUB 10←12 ok' \
  && expect_line '^DEP 12⇐11 fallback' \
  && ok "404 on dependencies prints fallback, sub-issues still wire, exit 0"

# ----------------------------------------------------------- 4. any other non-2xx → FAILED, exit 1
GH_DEP_STATUS=500 run_case "dependencies-500" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 \
  && expect_line '^SUB 10←11 ok' \
  && expect_line '^DEP 12⇐11 FAILED.*HTTP 500' \
  && ok "a 500 is FAILED with the status quoted, exit 1 — never read as fallback"

# Two children: the script keeps going after a FAILED edge and still reports every edge, and
# the summary line counts them — a script that exits on the first failure would report one.
GH_SUB_STATUS=503 run_case "sub-issues-503" --repo o/r --parent 10 --child 11 --child 12
expect_rc 1 && expect_line '^SUB 10←11 FAILED.*HTTP 503' && expect_line '^SUB 10←12 FAILED.*HTTP 503' \
  && expect_line '^wire-edges: 2 edge\(s\) — 0 ok, 0 fallback, 2 failed' \
  && ok "a 503 on sub_issues is FAILED too, every edge is still reported, exit 1"

# The bare `gh: HTTP <code>` form (non-JSON error body) is still a status: 404 → fallback, 500 → FAILED.
GH_PLAIN_ERROR=1 GH_DEP_STATUS=404 run_case "plain-404" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 && expect_line '^DEP 12⇐11 fallback' \
  && ok "a bare 'gh: HTTP 404' (no JSON body) still reads as fallback"
GH_PLAIN_ERROR=1 GH_DEP_STATUS=500 run_case "plain-500" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 && expect_line '^DEP 12⇐11 FAILED.*HTTP 500' \
  && ok "a bare 'gh: HTTP 500' is FAILED with the status quoted"

# ------------------------------------------------- 5. 422 "already exists" → ok (idempotent re-run)
# The two messages are the ones github.com actually returned on a second run (measured 2026-08-31
# against phmatray/ai-migration-kit, throwaway issues #346–#348): the sub-issue one says
# "duplicate", the dependency one says "already been taken". Neither says "exists".
GH_SUB_STATUS=422 GH_DEP_STATUS=422 \
  GH_422_MESSAGE="An error occurred while adding the sub-issue to the parent issue. Issue may not contain duplicate sub-issues and Sub issue may only have one parent" \
  run_case "422-duplicate-sub-issue" --repo o/r --parent 10 --child 11
expect_rc 0 && expect_line '^SUB 10←11 ok' \
  && ok "the live duplicate-sub-issue 422 is ok — re-running the wiring is safe"

GH_DEP_STATUS=422 \
  GH_422_MESSAGE="An error occurred while adding the blocking issue to the issue. Validation failed: Target issue has already been taken" \
  run_case "422-already-blocked" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 && expect_line '^SUB 10←11 ok' && expect_line '^DEP 12⇐11 ok' \
  && ok "the live already-taken dependency 422 is ok — re-running the wiring is safe"

# A 422 that is NOT an already-exists (a cycle, a cross-repo refusal) is a real failure.
GH_DEP_STATUS=422 GH_422_MESSAGE="Validation Failed: would create a cycle" \
  run_case "422-other" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 && expect_line '^DEP 12⇐11 FAILED.*HTTP 422' \
  && ok "any other 422 is FAILED, exit 1"

# --------------------------------------------------------- 6. an issue whose id cannot be resolved
GH_ISSUE_STATUS=404 run_case "id-lookup-404" --repo o/r --parent 10 --child 11
expect_rc 1 || true
if grep -qE 'POST' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a POST was sent although an id lookup failed"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
else
  ok "an unresolvable issue id stops before any POST, exit 1"
fi

# Only the LAST issue's lookup fails: a script that resolved ids lazily between POSTs would have
# posted the parent←11 edge before discovering #12 — the header promises every id is resolved
# before the first write.
GH_ISSUE_404_FOR=12 run_case "id-lookup-404-late" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 || true
if grep -qE 'POST' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a POST was sent before every id was resolved"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
else
  ok "ids are all resolved before the first POST — a late lookup failure posts nothing"
fi

# ------------------------------------------------------------------------- 7. usage errors → exit 2
run_case "no-parent" --repo o/r --child 11
expect_rc 2 && expect_no_calls && ok "missing --parent is exit 2 and calls nothing"

run_case "no-repo" --parent 10 --child 11
expect_rc 2 && expect_no_calls && ok "missing --repo is exit 2 and calls nothing"

run_case "no-child" --repo o/r --parent 10
expect_rc 2 && expect_no_calls && ok "no --child at all is exit 2 and calls nothing"

run_case "bad-child-spec" --repo o/r --parent 10 --child 11:blocked-by=eleven
expect_rc 2 && expect_no_calls && ok "a non-numeric blocker is exit 2 and calls nothing"

run_case "child-is-parent" --repo o/r --parent 10 --child 10
expect_rc 2 && expect_no_calls && ok "a child equal to the parent is exit 2 and calls nothing"

run_case "self-blocked" --repo o/r --parent 10 --child 11:blocked-by=11
expect_rc 2 && expect_no_calls && ok "a child blocked by itself is exit 2 and calls nothing"

run_case "blocked-by-parent" --repo o/r --parent 10 --child 11:blocked-by=10
expect_rc 2 && expect_no_calls && ok "a child blocked by the parent is exit 2 and calls nothing"

run_case "empty-blocker" --repo o/r --parent 10 --child 12:blocked-by=,11
expect_rc 2 && expect_no_calls && ok "an empty entry in the blocker list is exit 2 and calls nothing"

run_case "bare-blocked-by" --repo o/r --parent 10 --child 12:blocked-by=
expect_rc 2 && expect_no_calls && ok "a bare blocked-by= is exit 2 and calls nothing"

run_case "unknown-flag" --repo o/r --parent 10 --child 11 --bogus
expect_rc 2 && expect_no_calls && ok "an unknown flag is exit 2 and calls nothing"

# ----------------------------------------------------------------- 8. --dry-run prints, calls nothing
run_case "dry-run" --dry-run --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 && expect_no_calls \
  && expect_line 'POST repos/o/r/issues/10/sub_issues' \
  && expect_line 'POST repos/o/r/issues/12/dependencies/blocked_by' \
  && expect_no_line '^(SUB|DEP) .* (ok|fallback|FAILED)' \
  && ok "--dry-run prints the POSTs it would send and never invokes gh"

# ------------------------------------------------------------------------------------------ verdict
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "wire-edges golden test: all cases behaved as specified"
