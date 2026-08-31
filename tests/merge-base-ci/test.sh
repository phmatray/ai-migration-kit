#!/usr/bin/env bash
# Golden test for skills/merge-pr/scripts/base-run-verdict.sh (#355).
#
# WHAT BROKE. `merge-pr` gates hard on CI *before* the merge and then tears down at PR-green: it
# never reads the workflow run its own merge triggers on the base branch. Measured on this repo,
# 2026-08-30: #338's push run on `main` was CANCELLED (superseded 2m39s later by the next merge)
# and #342's run 33346395704 recorded the failure — nobody read either, `main` stayed red for ~40
# minutes, and every in-flight PR in the fleet inherited the red bar.
#
# WHAT THIS SUITE PINS. The one property that makes the answer attributable: the verdict is
# resolved FOR A SHA, never for "the newest run on the base branch". Under a merge train — which
# is the normal `auto-dev` shape, several merges within minutes — a sibling merge landing two
# seconds later would otherwise donate its run to this merge's verdict, and the report would name
# the wrong change. So the stub below deliberately arms a RECENCY TRAP: `gh run list` answers with
# a sibling sha's FAILING run, and any helper that asks that question instead of asking the
# check-runs endpoint about its own sha goes red here.
#
# The CI rules themselves are NOT re-derived here. The helper delegates them to the registered
# decision `ci.verdict` (#91, #170, #208) — the same reduction `merge-pr` Step 3 already runs, and
# the reason a superseded `cancelled` cannot mask a newer `success`. What this suite proves is the
# mapping around it: which ci.verdict word becomes green, which becomes red, and — the case the
# incident turns on — which becomes the honest NON-VERDICT `unverified`.
set -euo pipefail
cd "$(dirname "$0")/../.."

HELPER="./skills/merge-pr/scripts/base-run-verdict.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Scratch dir and EXIT trap from the shared preamble (#72).
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and the"
  echo "      decision this helper delegates to is written in it."
  exit 1; }

# The decision engine appends one event per run. Point it INTO the scratch dir: left to its own
# defaults it would write into the repository this suite is running from (#208's fail-open log).
export KIT_DECISION_LOG="$WORK/decision-events.jsonl"

# ------------------------------------------------------------------ the `gh` stub
#
# Only two questions are answerable, and they answer DIFFERENTLY on purpose:
#
#   * `api …/commits/<sha>/check-runs` — the real question. Serves the Nth canned response armed
#     for THAT sha (clamped to the last one, so a poll past the script repeats it — which is what
#     "the run never finishes" needs). A response starting with `ERR:` simulates gh failing: the
#     rest goes to stderr and the stub exits 1.
#   * `run list …` — the recency trap. Always the sibling merge's failing run, whatever was asked.
#     A helper that resolves by recency reads a red that is not its own.
#
# Anything else is an unhandled invocation and fails loudly rather than answering a question this
# suite never scripted.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
case "$*" in
  *check-runs*)
    sha=""
    for a in "$@"; do
      case "$a" in
        */commits/*/check-runs*)
          sha="${a#*/commits/}"
          sha="${sha%%/check-runs*}"
          ;;
      esac
    done
    [ -n "$sha" ] || { echo "STUB: no sha in the check-runs path: $*" >&2; exit 1; }
    dir="$GH_RESPONSES/$sha"
    # A sha nobody armed carries no check-runs. That is a real GitHub answer (a base branch with
    # no CI, or a run not posted yet), not a stub gap, so it is served rather than refused.
    [ -d "$dir" ] || { printf '%s' '[{"total_count":0,"check_runs":[]}]'; exit 0; }
    n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$dir/count"
    max=$(cat "$dir/max" 2>/dev/null || echo 1)
    use=$n
    [ "$use" -gt "$max" ] && use=$max
    content=$(cat "$dir/$use.json")
    case "$content" in
      ERR:*)
        printf '%s\n' "${content#ERR:}" >&2
        exit 1
        ;;
      *)
        printf '%s' "$content"
        ;;
    esac
    ;;
  *"run list"*)
    printf '%s' "$RUN_LIST_TRAP"
    ;;
  *)
    echo "STUB: unhandled gh invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# The sibling merge in the train: its run is red, and it is what every recency-shaped query
# returns. Nothing in this suite may ever report red because of it.
SIBLING_SHA=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
export RUN_LIST_TRAP='[{"databaseId":33346395704,"headSha":"'"$SIBLING_SHA"'","conclusion":"failure","status":"completed","name":"kit","url":"https://github.invalid/run/33346395704"}]'

# ------------------------------------------------------------------ arming helpers

# run <name> <id> <state> — one check-run object. `state` is written into `conclusion` for a
# finished run and into `status` for one that is not, which is the shape the check-runs API gives
# and the shape ci.verdict's `(.conclusion // .status)` reads.
run_obj() {
  local name="$1" id="$2" state="$3"
  case "$state" in
    queued|in_progress|waiting|requested|pending)
      printf '{"name":"%s","id":%s,"app":{"id":15368},"started_at":"2026-08-30T09:00:00Z","html_url":"https://github.invalid/checks/%s","status":"%s","conclusion":null}' \
        "$name" "$id" "$id" "$state" ;;
    *)
      printf '{"name":"%s","id":%s,"app":{"id":15368},"started_at":"2026-08-30T09:00:00Z","html_url":"https://github.invalid/checks/%s","status":"completed","conclusion":"%s"}' \
        "$name" "$id" "$id" "$state" ;;
  esac
}

# page <run-json>… — one --paginate --slurp page wrapping the given runs.
page() {
  local first=1 out='[{"total_count":0,"check_runs":['
  local r
  for r in "$@"; do
    [ "$first" -eq 1 ] || out="$out,"
    out="$out$r"
    first=0
  done
  printf '%s' "$out]}]"
}

# arm <sha> <page-1> [<page-2> …] — the scripted answers for one sha, poll by poll.
arm() {
  local sha="$1"; shift
  local dir="$GH_RESPONSES/$sha"
  rm -rf "$dir"; mkdir -p "$dir"
  local idx=1 resp
  for resp in "$@"; do
    printf '%s' "$resp" > "$dir/$idx.json"
    idx=$((idx + 1))
  done
  echo "$((idx - 1))" > "$dir/max"
}

# reset_case <name> — a fresh call log and a fresh response tree per case.
reset_case() {
  GH_CALL_LOG="$WORK/gh-calls.$1.log"
  GH_RESPONSES="$WORK/gh-resp.$1"
  export GH_CALL_LOG GH_RESPONSES
  rm -rf "$GH_RESPONSES"; mkdir -p "$GH_RESPONSES"
  : > "$GH_CALL_LOG"
}

# The helper always exits 0 and always prints one JSON object: a non-verdict is an ANSWER, not a
# failure, so a non-zero exit would give an autonomous merge a new way to stop after the merge has
# already landed. Assert both here, once, rather than at every call site.
verdict_of() {
  local out rc=0
  out=$("$HELPER" "$@" 2>"$WORK/helper.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: the helper exited $rc — a post-merge reader must always answer, never refuse:" >&2
    sed 's/^/      /' "$WORK/helper.err" >&2
    exit 1
  fi
  printf '%s' "$out" | jq -e . > /dev/null 2>&1 || {
    echo "FAIL: the helper did not print one JSON object:" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    exit 1; }
  printf '%s' "$out"
}

expect_verdict() {
  local label="$1" want="$2" got_json="$3" got
  got=$(printf '%s' "$got_json" | jq -r .verdict)
  [ "$got" = "$want" ] || {
    echo "FAIL [$label]: expected verdict '$want', got '$got'"
    printf '%s\n' "$got_json" | jq . | sed 's/^/      /'
    exit 1; }
}

# ---------------------------------------------------------------- 0. usage: no sha refuses
#
# The one case that is NOT a verdict: called with no sha there is nothing to resolve, and printing
# `unverified` would let a caller that forgot the argument report a clean non-verdict forever.
rc=0
out=$("$HELPER" 2>&1) || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL [usage]: expected exit 64 with no sha, got $rc"; echo "$out"; exit 1; }
echo "  ok: usage — no sha refuses with exit 64 rather than printing a non-verdict"

# ---------------------------------------------------------------- 1. resolved BY SHA, not by recency
#
# The merge-train case, and the reason this helper exists. Our sha is green; the sibling merge that
# landed two seconds later is red and is what every recency query answers. Green is the only
# correct verdict, and the call log must show the question was asked about our sha.
reset_case by-sha
SHA=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
arm "$SHA" "$(page "$(run_obj kit 501 success)" "$(run_obj title-gate 502 success)")"
arm "$SIBLING_SHA" "$(page "$(run_obj kit 601 failure)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict by-sha green "$v"
grep -qF "commits/$SHA/check-runs" "$GH_CALL_LOG" || {
  echo "FAIL [by-sha]: the helper never asked the check-runs endpoint about $SHA:"
  sed 's/^/      /' "$GH_CALL_LOG"; exit 1; }
if grep -qF 'run list' "$GH_CALL_LOG"; then
  echo "FAIL [by-sha]: the helper asked a recency-shaped question (\`gh run list\`). A sibling"
  echo "      merge's run must not be able to donate its verdict to this sha:"
  sed 's/^/      /' "$GH_CALL_LOG"; exit 1
fi
echo "  ok: by-sha — a green sha reports green even though the newest run on the branch is red"

# ---------------------------------------------------------------- 2. a sibling sha's run is refused
#
# The mirror of case 1, in the direction that matters more: OUR merge is the one that broke the
# base. A green sibling landing after it must not launder that red into a pass.
reset_case sibling-refused
SHA=c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
arm "$SHA" "$(page "$(run_obj kit 701 failure)")"
arm "$SIBLING_SHA" "$(page "$(run_obj kit 702 success)")"
export RUN_LIST_TRAP='[{"databaseId":33346400000,"headSha":"'"$SIBLING_SHA"'","conclusion":"success","status":"completed","name":"kit","url":"https://github.invalid/run/33346400000"}]'
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict sibling-refused red "$v"
printf '%s' "$v" | jq -e '.runs | map(select(.state == "failure")) | length == 1' > /dev/null || {
  echo "FAIL [sibling-refused]: the failing job is not named in .runs — a filed bug needs it:"
  printf '%s\n' "$v" | jq . | sed 's/^/      /'; exit 1; }
echo "  ok: sibling-refused — a red sha stays red even though a sibling merge's newer run is green"
# Restore the red trap for the cases below.
export RUN_LIST_TRAP='[{"databaseId":33346395704,"headSha":"'"$SIBLING_SHA"'","conclusion":"failure","status":"completed","name":"kit","url":"https://github.invalid/run/33346395704"}]'

# ---------------------------------------------------------------- 3. no run for the sha → unverified
#
# A base branch with no CI, or a run GitHub has not posted yet. `ci.verdict` calls this `no-ci`,
# which for a PRE-merge gate means "let mergeStateStatus decide" — but here the merge has already
# happened, and the honest report is that this merge's effect on the base was never verified.
# Reporting it as green is the regression this whole issue exists to prevent.
reset_case no-run
SHA=d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
# Nothing armed for $SHA at all: the stub serves an empty check_runs page, exactly as GitHub does.
arm "$SIBLING_SHA" "$(page "$(run_obj kit 801 success)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict no-run unverified "$v"
printf '%s' "$v" | jq -e '.reason == "no-ci"' > /dev/null || {
  echo "FAIL [no-run]: expected reason 'no-ci', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: no-run — a sha with no check-runs is unverified, never green"


# ---------------------------------------------------------------- 4. a cancelled run is a NON-verdict
#
# `dce7d5b`, exactly. `cancel-in-progress` (#27/#29) cancels the previous `main` run the moment the
# next merge lands, so under a fleet this is the ROUTINE outcome of a merge train — and it is the
# shape that made the incident invisible. `ci.verdict` files a cancelled job under `.failed`,
# because pre-merge a cancelled check is a reason not to merge; post-merge the merge has already
# landed and the run recorded nothing about it. Reporting that as `red` would file a bug against a
# merge nobody has evidence about; reporting it as `green` is the silence #355 exists to end.
reset_case cancelled-only
SHA=e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5
arm "$SHA" "$(page "$(run_obj kit 901 cancelled)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict cancelled-only unverified "$v"
printf '%s' "$v" | jq -e '.reason == "cancelled"' > /dev/null || {
  echo "FAIL [cancelled-only]: expected reason 'cancelled', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: cancelled-only — a sha whose only run was cancelled is unverified, not red and not green"

# ---------------------------------------------------------------- 5. a SUPERSEDED cancellation is noise
#
# The other half of the same rule, and the one that keeps case 4 from becoming "ignore cancelled
# runs": a cancelled run with a NEWER run of the same job behind it was superseded, and the newer
# run is the verdict. That reduction is `ci.verdict`'s (#91), not this helper's — this case proves
# the helper still delegates to it rather than short-circuiting on the word `cancelled`.
reset_case superseded-cancel
SHA=f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6
arm "$SHA" "$(page "$(run_obj kit 910 cancelled)" "$(run_obj kit 911 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict superseded-cancel green "$v"
printf '%s' "$v" | jq -e '.runs | length == 1' > /dev/null || {
  echo "FAIL [superseded-cancel]: .runs is the raw history, not the reduced one-run-per-job set:"
  printf '%s\n' "$v" | jq . | sed 's/^/      /'; exit 1; }
echo "  ok: superseded-cancel — a cancelled run behind a newer success is green, via ci.verdict's reduction"

# ---------------------------------------------------------------- 6. cancelled must not swallow a real red
#
# One job cancelled beside another job that genuinely FAILED. `red` is the answer: there is real
# evidence of a breakage, and case 4's carve-out must not launder it into a non-verdict.
reset_case cancelled-plus-failure
SHA=0707070707070707070707070707070707070707
arm "$SHA" "$(page "$(run_obj kit 920 cancelled)" "$(run_obj title-gate 921 failure)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict cancelled-plus-failure red "$v"
echo "  ok: cancelled-plus-failure — a cancelled job beside a real failure still reports red"

# ---------------------------------------------------------------- 7. pending polls, then answers
#
# The run is still going when the merge returns — the normal case, since the push run starts the
# half-second after. Two pending polls, then the verdict.
reset_case pending-then-green
SHA=1818181818181818181818181818181818181818
arm "$SHA" \
  "$(page "$(run_obj kit 930 in_progress)")" \
  "$(page "$(run_obj kit 930 in_progress)")" \
  "$(page "$(run_obj kit 930 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict pending-then-green green "$v"
[ "$(cat "$GH_RESPONSES/$SHA/count")" -ge 3 ] || {
  echo "FAIL [pending-then-green]: the helper stopped polling before the run finished"; exit 1; }
echo "  ok: pending-then-green — a still-running base run is polled until it is final"

# ---------------------------------------------------------------- 8. the bound expires → unverified
#
# A run that never finishes inside the bound. `unverified`, NEVER `red`: a helper that reported a
# slow run as a breakage would file bugs against healthy merges, which is a worse failure than the
# silence it replaces.
reset_case pending-forever
SHA=2929292929292929292929292929292929292929
arm "$SHA" "$(page "$(run_obj kit 940 queued)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict pending-forever unverified "$v"
printf '%s' "$v" | jq -e '.reason == "timeout"' > /dev/null || {
  echo "FAIL [pending-forever]: expected reason 'timeout', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: pending-forever — an expired bound is a stated non-verdict, never a breakage"

# ---------------------------------------------------------------- 9. a transient gh failure is not an answer
#
# `gh` failing says nothing about the base branch, so it must not read as `no-ci` (case 3's green-
# adjacent silence) on the first attempt. Two failures, then the real answer.
reset_case transient-error
SHA=3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a
arm "$SHA" \
  'ERR:API rate limit exceeded' \
  'ERR:context deadline exceeded' \
  "$(page "$(run_obj kit 950 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict transient-error green "$v"
echo "  ok: transient-error — a failing gh call is retried, not reported as 'no CI on the base'"

# ---------------------------------------------------------------- 10. a query that never answers
#
# The same failure, past the bound. It is a non-verdict with its own reason, so a report can say
# WHY there is no answer — "the base was never verified because the query failed" and "…because
# the run never finished" send a reader to different places.
reset_case query-failed
SHA=4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b
arm "$SHA" 'ERR:API rate limit exceeded'
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict query-failed unverified "$v"
printf '%s' "$v" | jq -e '.reason == "query-failed"' > /dev/null || {
  echo "FAIL [query-failed]: expected reason 'query-failed', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: query-failed — a gh call that never answers is its own named non-verdict"

# ---------------------------------------------------------------- 11. `no-ci` is not answered on
# the first poll — it is indistinguishable from "GitHub has not posted the run yet"
#
# This helper runs SECONDS after `gh pr merge` returned, and the push run's check-runs are not
# posted instantly. Answering `no-ci` on the first reading would make `unverified` the outcome of
# almost every healthy merge, with the whole timeout budget unused — a step that always reports a
# non-verdict is the silence #355 removes, wearing a different word. So `no-ci` is retried until
# the settle window expires, and only then is it an answer (case 3 is that expiry, with the window
# clamped to a zero timeout).
reset_case no-ci-settles
SHA=5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c
arm "$SHA" \
  "$(page)" \
  "$(page)" \
  "$(page "$(run_obj kit 960 success)")"
v=$(verdict_of "$SHA" --timeout 60 --settle 60 --poll-seconds 0)
expect_verdict no-ci-settles green "$v"
[ "$(cat "$GH_RESPONSES/$SHA/count")" -ge 3 ] || {
  echo "FAIL [no-ci-settles]: the helper answered before the run was posted"; exit 1; }
echo "  ok: no-ci-settles — an empty check-run set is retried inside the settle window, not answered"

# ---------------------------------------------------------------- 12. a partly-posted job graph is
# not green yet
#
# The mirror hazard, and the one that would report a broken base as clean: a fast job's check-run
# exists and is green while a job behind a \`needs:\` chain has not posted at all. The reduction
# calls that set clear — correctly, on the evidence it has. SKILL.md §3 already makes this argument
# for the PRE-merge gate ("wait one poll interval and re-derive"); post-merge the window is widest,
# so `clear` counts only once the reduced JOB SET matches the previous poll's.
reset_case late-job
SHA=6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d
arm "$SHA" \
  "$(page "$(run_obj kit 970 success)")" \
  "$(page "$(run_obj kit 970 success)" "$(run_obj deploy 971 queued)")" \
  "$(page "$(run_obj kit 970 success)" "$(run_obj deploy 971 failure)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict late-job red "$v"
[ "$(cat "$GH_RESPONSES/$SHA/count")" -ge 3 ] || {
  echo "FAIL [late-job]: the helper called it on the first reading, before the graph had posted"; exit 1; }
echo "  ok: late-job — a green first reading is re-derived, so a job that posts a beat later still counts"

echo "merge-base-ci golden test OK"
