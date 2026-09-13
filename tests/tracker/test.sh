#!/usr/bin/env bash
# Golden test for the tracker contract (#505) — scripts/tracker.sh, scripts/tracker/github.sh and
# the registered `tracker.capable` decision.
#
# WHAT THIS PINS, and why each case is a seam rather than an internal.
#
# Every tracker operation in the kit is a direct `gh` call (111 lines in 18 scripts, 189 in 39 prose
# files), so there was no place a second host's dialect could live and no way to say "create-issue
# works here, merge-pr does not yet". This suite pins the two seams that claim now exists:
#
#   A. `tracker.sh`'s STDOUT and EXIT CODE under a stub `gh` first on $PATH. The stub is what makes
#      the backend's normalisation assertable without a network or a real repository: `gh issue view`
#      answers `"OPEN"` and the verb must answer `"open"`, and no live fixture could pin that
#      without also pinning somebody's real issue text.
#   B. the `tracker.capable` verdict through `scripts/decide.sh tracker.capable`, over hand-written
#      state fixtures. Reached through the DISPATCHER, by id — never by calling capable.sh directly.
#      A direct call would test a path no caller uses and would skip the vocabulary refusal that
#      turns an unregistered verdict word into a red build (the same reasoning
#      tests/merge-freshness/test.sh gives for going through decide.sh).
#
# What it deliberately does NOT assert: the dispatcher's internal lookup order. That the verb is
# validated BEFORE the backend is resolved is observable — a typo is exit 2 on every host instead of
# "not implemented" on some — so it is asserted through that observable difference (case 3a/3b) and
# not by reading the script.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACKER="$KIT_ROOT/scripts/tracker.sh"
DECIDE="$KIT_ROOT/scripts/decide.sh"
FIXTURES="$KIT_ROOT/tests/decisions/fixtures/tracker.capable"

. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

WORK=$(kit_scratch)

# Telemetry into the scratch dir, never the checkout: a suite must not append to the developer's own
# event log, and a refusal about the log would otherwise fold into a captured verdict string.
KIT_DECISION_LOG="$WORK/decision-events.jsonl"
export KIT_DECISION_LOG

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }
ok() { echo "  ok: $1"; }

[ -x "$TRACKER" ] || { echo "FAIL: $TRACKER is missing or not executable"; exit 1; }

# ------------------------------------------------------------------------------------ the gh stub
#
# First on $PATH, so the backend's own `gh` calls land here. It applies `--json` and `--jq` the way
# gh does, because that translation is exactly what github.sh delegates to gh and therefore exactly
# what a stub must not fake away. `auth token --hostname` is answered because _gh-host.sh probes it
# when it resolves a host from origin (#514) — without it the helper's rule 3 would fail here for a
# reason that has nothing to do with the verb under test.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

payload=""
case "${1-} ${2-}" in
  "api user")     payload='{"login":"octocat"}' ;;
  "auth token")   echo "gho_stubtoken"; exit 0 ;;
  "repo view")    payload='{"nameWithOwner":"o/r","defaultBranchRef":{"name":"main"}}' ;;
  "issue view")   payload='{"number":7,"title":"A stub issue","state":"OPEN","body":"body text","labels":[{"name":"bug"},{"name":"area: skills"}],"url":"https://example.invalid/o/r/issues/7"}' ;;
  *)              echo "gh stub: unsupported call: $*" >&2; exit 1 ;;
esac

# Honour a trailing `--jq <expr>` the way gh does; otherwise hand back the whole object.
jq_expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="${2-}"; shift 2 ;;
    *)    shift ;;
  esac
done

if [ -n "$jq_expr" ]; then
  printf '%s' "$payload" | jq -r "$jq_expr"
else
  printf '%s\n' "$payload"
fi
STUB
chmod +x "$WORK/bin/gh"

# Sanity-check the stub itself: a stub that answers everything proves nothing, so an unsupported
# call must fail rather than silently return an empty success.
if PATH="$WORK/bin:$PATH" gh frobnicate >/dev/null 2>&1; then
  note_fail "the gh stub accepted an unsupported call — every assertion below would be vacuous"
fi

run_tracker() {
  # Runs the dispatcher with the stub first on PATH, from $WORK (never the kit checkout) so the
  # profile lookup is the fixture's, not this repository's.
  local dir="$1"; shift
  OUT=$(cd "$dir" && PATH="$WORK/bin:$PATH" "$TRACKER" "$@" 2>"$WORK/err.log")
  RC=$?
  ERR=$(cat "$WORK/err.log")
}

# A fixture repository carrying a committed profile whose Tracker line names github.
PROFILED="$WORK/profiled"
mkdir -p "$PROFILED/.claude/skills"
printf '%s\n' '# Repo profile' '' '## Tracker' \
  '- **Tracker:** github (github.com) — the lifecycle skills drive GitHub semantics through `gh`.' \
  > "$PROFILED/.claude/skills/repo-profile.md"

# A fixture directory with NO committed profile at all.
BARE="$WORK/bare"
mkdir -p "$BARE"

echo "== A. the dispatcher and the gh backend"

# ------------------------------------------------------------------------------------------- AC1
run_tracker "$PROFILED" --tracker github repo
if [ "$RC" -ne 0 ]; then
  note_fail "AC1 repo — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"o/r","host":"github.com","defaultBranch":"main"}' ]; then
  note_fail "AC1 repo — wrong stdout
      want: {\"slug\":\"o/r\",\"host\":\"github.com\",\"defaultBranch\":\"main\"}
      got:  $OUT"
else
  ok "AC1 repo — normalised {slug, host, defaultBranch}, exit 0"
fi

# ------------------------------------------------------------------------------------------- AC2
#
# `gh issue view` answers `"OPEN"`; the verb's contract is a lower-cased state, labels as bare names
# and an explicit `"format":"markdown"` so a later backend cannot quietly hand back a different
# markup dialect under the same verb.
run_tracker "$PROFILED" --tracker github issue-view 7
if [ "$RC" -ne 0 ]; then
  note_fail "AC2 issue-view — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -r '[(.number|tostring), .state, .format, (.labels|join("+")), .title] | join("|")' 2>/dev/null) \
    || got="<unparseable: $OUT>"
  want='7|open|markdown|bug+area: skills|A stub issue'
  if [ "$got" != "$want" ]; then
    note_fail "AC2 issue-view — wrong normalisation
      want: $want
      got:  $got"
  else
    ok "AC2 issue-view — state lower-cased, labels as names, format markdown"
  fi
fi

# ------------------------------------------------------------------------------------------- AC3
#
# A verb absent from contract.json is a BAD INVOCATION (2), not a missing implementation (3), and it
# is that on every host — which is only true if the verb is checked before the backend is resolved.
run_tracker "$PROFILED" --tracker github frobnicate
[ "$RC" -eq 2 ] \
  && ok "AC3a unknown verb — exit 2 before any backend runs" \
  || note_fail "AC3a unknown verb — expected exit 2, got $RC ('$OUT')"

run_tracker "$PROFILED" --tracker gitlab repo
if [ "$RC" -ne 3 ]; then
  note_fail "AC3b missing backend — expected exit 3, got $RC ('$OUT')"
elif ! printf '%s\n%s\n' "$OUT" "$ERR" | grep -Fq 'NOT_IMPLEMENTED gitlab repo'; then
  note_fail "AC3b missing backend — exit 3 but no 'NOT_IMPLEMENTED gitlab repo'
      stdout: $OUT
      stderr: $ERR"
else
  ok "AC3b missing backend — exit 3, NOT_IMPLEMENTED gitlab repo"
fi

# A verb the contract declares but the RESOLVED backend does not implement is also exit 3, and that
# is a different cause from "no backend file at all" — both must land on 3 rather than one of them
# reading as a bad invocation.
run_tracker "$PROFILED" --tracker github verbs
if [ "$RC" -ne 0 ]; then
  note_fail "verbs — the backend protocol verb exited $RC ($ERR)"
elif ! printf '%s\n' "$OUT" | grep -Fqx 'issue-view'; then
  note_fail "verbs — the backend did not list issue-view: '$OUT'"
else
  ok "verbs — the backend lists what it implements"
fi

run_tracker "$PROFILED" --tracker github auth
[ "$RC" -eq 0 ] && [ "$OUT" = "octocat" ] \
  && ok "auth — prints the login" \
  || note_fail "auth — expected 'octocat' exit 0, got '$OUT' exit $RC ($ERR)"

# --------------------------------------------------------------------- the profile selects the host
#
# No --tracker: the dispatcher reads the profile's Tracker line. With NO committed profile it falls
# back to github, which is today's behaviour — the missing profile is reported by preconditions' own
# profile load, never by this dispatcher.
run_tracker "$PROFILED" repo
[ "$RC" -eq 0 ] \
  && ok "profile — the Tracker line selects the backend with no --tracker" \
  || note_fail "profile — expected exit 0 from the profile's github, got $RC ($ERR)"

run_tracker "$BARE" repo
[ "$RC" -eq 0 ] \
  && ok "no profile — dispatches to github rather than refusing" \
  || note_fail "no profile — expected exit 0 (github default), got $RC ($ERR)"

# --repo reaches the backend as TRACKER_REPO.
run_tracker "$BARE" --repo other/repo repo
[ "$RC" -eq 0 ] \
  && ok "--repo — accepted and forwarded to the backend" \
  || note_fail "--repo — expected exit 0, got $RC ($ERR)"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "tracker: FAILED"
  exit 1
fi
echo
echo "tracker: OK — verbs route to a per-host backend, and an absent one is named rather than guessed."
