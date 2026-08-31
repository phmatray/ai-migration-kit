#!/usr/bin/env bash
# wire-edges.sh — wire a decomposed issue's edges on GitHub: every child as a SUB-ISSUE of the
# parent, every child's blockers as native BLOCKED_BY dependencies. Second pass of create-issue's
# decompose branch (#315): issues need numbers before they can reference each other, so the skill
# files the parent and the children first (blockers before the children they block) and then runs
# this once with the numbers it got back.
#
#   wire-edges.sh --repo <owner>/<repo> --parent <N> --child <C>[:blocked-by=<A>[,<B>…]] … [--dry-run]
#
# Output, one line per edge, on stdout:
#
#   SUB <parent>←<child>    ok | fallback | FAILED (HTTP <code>: <message>)
#   DEP <child>⇐<blocker>   ok | fallback | FAILED (HTTP <code>: <message>)
#
# Exit codes:
#   0   every edge is ok or fallback — the decomposition is wired as far as this host allows
#   1   any edge FAILED, or an issue's database id could not be resolved (nothing was posted after
#       that point: a POST built on a guessed id is worse than no POST)
#   2   usage — the arguments are wrong; nothing was called
#
# The rules that matter:
#
#   * `fallback` is a 404 on the POST. Sub-issues and issue dependencies are GA on github.com and
#     may be absent on GHES; either endpoint answering 404 means the FEATURE is off, not that the
#     issue is missing — every issue number was already resolved to its database id through a
#     successful GET before any POST, so "issue not found" cannot reach here as a 404. The child
#     body's text `**Blocked by:** #a, #b` line (which the skill always writes, wired or not) is
#     the representation that survives, and the skill's report says so.
#   * A 422 whose message says the edge already exists is `ok`: re-running the wiring after a
#     partial run must converge, not fail. Any OTHER 422 (a cycle, a cross-repo refusal) is FAILED.
#   * Ids are DATABASE ids (`gh api repos/o/r/issues/N --jq .id`), never the `#number` and never
#     the GraphQL node_id — the dependency endpoint rejects both, and it rejects the number with
#     a 404 that a careless reader would file under "feature off".
#   * `--dry-run` prints the POSTs it would send and calls `gh` NOT AT ALL — not even the id
#     lookups — so a skill can show the plan before a single write.
#
# Sources: ported from mattpocock/skills (MIT) — `engineering/to-tickets` (publish blockers first
# so edges can reference real identifiers; native blocking where the tracker has it) and
# `engineering/setup-matt-pocock-skills/issue-tracker-github.md` (the exact endpoints, and the
# database-id rule). Credit belongs to Matt Pocock; the fallback contract and the exit-code table
# are this kit's.
#
# bash 3.2 compatible (no associative arrays, no `${var,,}`, no `mapfile`). Tested by
# tests/wire-edges/test.sh through a stubbed `gh` on PATH.
set -euo pipefail

TOOL="wire-edges"

usage() {
  sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;s/^# \{0,1\}//;p;}' "$0"
}

refuse() {
  echo "$TOOL: REFUSED — $*" >&2
  exit 2
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

REPO=""
PARENT=""
DRY_RUN=0
CHILD_SPECS=""      # newline-separated "<child> <blocker> <blocker>…" records (bash 3.2: no arrays of arrays)
CHILD_COUNT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || refuse "--repo needs a value"
      REPO="$2"; shift 2 ;;
    --parent)
      [ $# -ge 2 ] || refuse "--parent needs a value"
      PARENT="$2"; shift 2 ;;
    --child)
      [ $# -ge 2 ] || refuse "--child needs a value"
      spec="$2"; shift 2
      child="${spec%%:*}"
      blockers=""
      if [ "$child" != "$spec" ]; then
        rest="${spec#*:}"
        case "$rest" in
          blocked-by=*)
            list="${rest#blocked-by=}"
            # An empty entry (`blocked-by=`, `blocked-by=,12`, a `$C1` that came back empty from a
            # failed create) must not silently wire one blocker fewer and print ok.
            case ",$list," in
              *,,*) refuse "--child '$spec': empty blocker in the list" ;;
            esac
            blockers=$(printf '%s' "$list" | tr ',' ' ') ;;
          *) refuse "--child '$spec': expected <N> or <N>:blocked-by=<A>[,<B>…]" ;;
        esac
      fi
      is_number "$child" || refuse "--child '$spec': '$child' is not an issue number"
      for b in $blockers; do
        is_number "$b" || refuse "--child '$spec': blocker '$b' is not an issue number"
        [ "$b" != "$child" ] || refuse "--child '$spec': #$child cannot be blocked by itself"
      done
      CHILD_SPECS="$CHILD_SPECS$child $blockers
"
      CHILD_COUNT=$((CHILD_COUNT + 1)) ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) refuse "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$REPO" ] || refuse "--repo <owner>/<repo> is required"
case "$REPO" in
  */*/*|*/|/*|*[[:space:]]*) refuse "--repo '$REPO' is not <owner>/<repo>" ;;
  */*) ;;
  *) refuse "--repo '$REPO' is not <owner>/<repo>" ;;
esac
[ -n "$PARENT" ] || refuse "--parent <N> is required"
is_number "$PARENT" || refuse "--parent '$PARENT' is not an issue number"
[ "$CHILD_COUNT" -gt 0 ] || refuse "at least one --child is required"
printf '%s' "$CHILD_SPECS" | while read -r child blockers; do
  [ -n "$child" ] || continue
  [ "$child" != "$PARENT" ] || { echo "$TOOL: REFUSED — child #$child is the parent" >&2; exit 2; }
  for b in $blockers; do
    [ "$b" != "$PARENT" ] || { echo "$TOOL: REFUSED — child #$child is blocked by the parent #$PARENT; the parent is a tracking issue, never a blocker" >&2; exit 2; }
  done
done || exit 2

# ------------------------------------------------------------------------------------- dry run
if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$CHILD_SPECS" | while read -r child blockers; do
    [ -n "$child" ] || continue
    echo "DRY-RUN POST repos/$REPO/issues/$PARENT/sub_issues -F sub_issue_id=<database id of #$child>"
    for b in $blockers; do
      echo "DRY-RUN POST repos/$REPO/issues/$child/dependencies/blocked_by -F issue_id=<database id of #$b>"
    done
  done
  echo "$TOOL: dry run — nothing was sent"
  exit 0
fi

# ------------------------------------------------------------------------------ id resolution
# One lookup per issue, cached in a temp file as "<number> <id>" lines. A lookup that fails is
# exit 1 BEFORE any POST: a database id is what the write endpoints key on, and there is no
# useful guess for one.
IDS=$(mktemp "${TMPDIR:-/tmp}/wire-edges-ids.XXXXXX") || { echo "$TOOL: cannot create a temp file" >&2; exit 1; }
trap 'rm -f "$IDS"' EXIT

id_of() {
  local n="$1" id
  id=$(awk -v n="$n" '$1 == n { print $2; exit }' "$IDS")
  if [ -z "$id" ]; then
    if ! id=$(gh api -H "Accept: application/vnd.github+json" "repos/$REPO/issues/$n" --jq .id 2>"$IDS.err"); then
      echo "$TOOL: cannot resolve the database id of #$n — $(tr '\n' ' ' < "$IDS.err")" >&2
      rm -f "$IDS.err"
      exit 1
    fi
    rm -f "$IDS.err"
    is_number "$id" || { echo "$TOOL: #$n resolved to '$id', which is not a database id" >&2; exit 1; }
    echo "$n $id" >> "$IDS"
  fi
  printf '%s' "$id"
}

# Resolve every id up front, so a missing issue is reported before the first write rather than
# between two of them.
for n in $PARENT $(printf '%s' "$CHILD_SPECS" | tr '\n' ' '); do
  id_of "$n" > /dev/null
done

# ------------------------------------------------------------------------------------ the POSTs
# post <endpoint> <field>=<value> → prints ok | fallback | FAILED (HTTP <code>: <message>)
# and returns 0 for ok/fallback, 1 for FAILED. `gh api` reports a non-2xx as
# `gh: <message> (HTTP <code>)` on stderr and exit 1; `--silent` drops the JSON body on stdout.
post() {
  local endpoint="$1" field="$2" err code msg
  if err=$(gh api -H "Accept: application/vnd.github+json" --method POST --silent "$endpoint" -F "$field" 2>&1 >/dev/null); then
    echo "ok"; return 0
  fi
  # Two spellings: `gh: <message> (HTTP <code>)` when the error body was JSON with a message,
  # and a bare `gh: HTTP <code>` when it was not (a proxy's HTML 404 in front of a GHES host).
  # The second must still read as a status — a plain-text 404 is the fallback case, not a
  # "no status" failure.
  code=$(printf '%s' "$err" | sed -n 's/.*HTTP \([0-9][0-9][0-9]\))\{0,1\}$/\1/p' | head -1)
  msg=$(printf '%s' "$err" | sed -n 's/^gh: \(.*\) (HTTP [0-9][0-9][0-9])$/\1/p' | head -1)
  [ -n "$msg" ] || msg=$(printf '%s' "$err" | tr '\n' ' ')
  case "$code" in
    404) echo "fallback"; return 0 ;;
    422)
      # Measured on github.com (2026-08-31, throwaway issues #346–#348): a second sub_issues POST
      # answers "Issue may not contain duplicate sub-issues and Sub issue may only have one
      # parent"; a second blocked_by POST answers "Validation failed: Target issue has already
      # been taken". `exists` covers the phrasing drifting. Anything else under 422 is a real
      # refusal — a cycle, a cross-repository edge — and stays FAILED.
      case "$msg" in
        *already*|*Already*|*duplicate*|*Duplicate*|*exists*)
          echo "ok (already wired)"; return 0 ;;
      esac
      echo "FAILED (HTTP 422: $msg)"; return 1 ;;
    '') echo "FAILED (no HTTP status in gh's answer: $msg)"; return 1 ;;
    *)  echo "FAILED (HTTP $code: $msg)"; return 1 ;;
  esac
}

n_ok=0; n_fallback=0; n_failed=0
count() {
  case "$1" in
    ok*) n_ok=$((n_ok + 1)) ;;
    fallback) n_fallback=$((n_fallback + 1)) ;;
    *) n_failed=$((n_failed + 1)) ;;
  esac
}

# The loop reads from a here-string rather than a pipe so the counters survive it (a piped
# `while` runs in a subshell under bash 3.2 and 4 alike).
while read -r child blockers; do
  [ -n "$child" ] || continue
  verdict=$(post "repos/$REPO/issues/$PARENT/sub_issues" "sub_issue_id=$(id_of "$child")") || true
  echo "SUB $PARENT←$child $verdict"
  count "$verdict"
  for b in $blockers; do
    verdict=$(post "repos/$REPO/issues/$child/dependencies/blocked_by" "issue_id=$(id_of "$b")") || true
    echo "DEP $child⇐$b $verdict"
    count "$verdict"
  done
done <<EOF
$CHILD_SPECS
EOF

echo "$TOOL: $((n_ok + n_fallback + n_failed)) edge(s) — $n_ok ok, $n_fallback fallback, $n_failed failed"
[ "$n_failed" -eq 0 ] || exit 1
exit 0
