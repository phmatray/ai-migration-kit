#!/usr/bin/env bash
# plan-freshness.sh — a plan promises to MODIFY paths; prove they still exist before building.
#
# Why this exists (#322). `create-issue` writes an implementation plan the day the issue is filed;
# `implement-issue` executes it whenever the issue reaches the front of the queue — weeks later,
# across dozens of merges. #233 and #245 both trace to a `**Files:**` line naming a path `main` no
# longer had. The failure is absence-shaped, the shape this repo keeps closing: nothing reports a
# problem. A per-task subagent opens the named file, does not find it, improvises the nearest
# thing, its filtered test goes green, the box gets ticked, and Step 10 never mentions that the
# plan it just executed described a different tree.
#
# So the question gets asked ONCE, up front, mechanically, before the draft PR exists. Every path
# a plan says it will `modify`, `test` or `delete` is resolved against a base ref; a path that does
# not resolve is named, and the exit status says so.
#
# Ported alongside the two-axis review in ../references/spec-review.md from mattpocock/skills
# (MIT) — `engineering/code-review` and `in-progress/implement-spec`.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not edit the plan, contact GitHub, or decide anything.
# Re-anchoring a stale path through the task's `**Interfaces:**` line is SKILL.md Step 2's job and
# a judgement call; this script only reports. `tick-plan.sh` owns the plan's round-trip contract
# (#199, #215) and is not touched here — freshness is a read of a ref, a separate concern.
#
# Usage:
#   plan-freshness.sh [-C <dir>] [--base <ref>] <plan.md>
#
#   -C <dir>       run git in this directory (default: the current one)
#   --base <ref>   the ref every path is resolved against (default: origin/main)
#   <plan.md>      the plan file the locate recipe already produced (/tmp/plan-<issue>.md)
#
# Output — one line per path named on a `**Files:**` line under a `### Task N` heading:
#
#   OK      modify <path> (Task N)     it resolves against <ref>
#   MISSING modify <path> (Task N)     it does not — the plan is stale here
#   SKIP    create <path> (Task N)     a path the plan is about to CREATE; absence is correct
#   SKIP    test   <path> (Task N)     ditto, marked `(new)`/`(new file)` on a verb other than
#                                      `create` (#433) — same reading, original verb word kept
#
# `(Task N)` is on ALL THREE lines, not only on MISSING: the task number is what Step 2 needs to
# find the `**Interfaces:**` line to re-anchor through, and a reader diffing two runs wants the OK
# lines attributable too. It is the wider of the two shapes #322 described and satisfies both.
#
# Verbs are `create|modify|test|delete`; only `modify`, `test` and `delete` are resolved, and a
# verb carries across the items after it, so `modify a, b; create c` checks a and b and skips c.
# A `**Files:**` line that names no verb at all is read as `modify` — the checked reading, because
# the alternative silently un-gates the line.
#
# An item's own trailing `(new)`/`(new file)` marker reads the same way regardless of its verb
# word (#433). `create-issue`'s own template writes a task's own new test file as
# `test \`path\` (new)`, not `create \`path\`` — the item is "the test for this task", not "a file
# this task modifies" — and a bare `test`/`modify`/`delete` verb otherwise means "resolve this
# against <ref>", which is wrong for a path the plan itself says does not exist yet. So that one
# marker is read BEFORE the generic aside-strip below discards it as ordinary noise (the same way
# `(DI registration)` is noise): it downgrades the item's OK/MISSING check to the `create` verb's
# SKIP, printed with the ORIGINAL verb word so the reader still sees what the plan actually wrote.
# Exact phrases only, case-insensitive, isolated (not substring) — `(new in v2)` is not this marker,
# matching the same closed-list discipline the `none expected.` idiom below already uses.
#
# Every task still needs a `**Files:**` line even when it touches no file at all (a
# verification-only task) — `create-issue` has been OBSERVED writing `none expected.` for exactly
# that case (#396's Task 4, #397's Task 4). `plan-shape.md` does not itself codify that wording, so
# this is a closed list of what has actually been seen, not a contract the two skills share; if
# `create-issue` ever phrases a no-file task differently, the same silent-STALE failure this fix
# closes can recur, and `plan-shape.md` is where the canonical wording belongs once that happens.
# That phrase names no path, so after an item is fully trimmed (verb prefix, backticks, trailing
# punctuation) it is matched against the list and, on a match, yields no OK/MISSING/SKIP line at
# all — the same "nothing to check" verdict as an empty item, never a path to resolve. Anything
# else — including a genuine typo like `none-such.md` — still falls through to the real check below
# and can still MISSING; "none" is not a magic word.
#
# Exit codes:
#   0  every checked path resolves — the plan still matches the tree
#   5  at least one does not; the MISSING lines name them. The guards' convention: a distinct code
#      for the expected non-success, so a caller can tell "stale" from "could not tell"
#   2  usage / plumbing error — no plan file, an unreadable one, no `### Task` in it, not a git
#      directory, or a base ref that does not resolve. NO VERDICT was reached, which is not a pass
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

die2() { echo "plan-freshness: $1" >&2; exit 2; }

# Trimming and splitting are done with `case` globs and `${…#…}`/`${…%…}` rather than sed: the
# repo runs its scripts under macOS's bash 3.2 AND BSD sed, where `s/…/\n/` in a replacement is not
# a newline, so the portable spelling of "split on two-character separators" is this one.
#
# `\r` is trimmed alongside the spaces, and it is not hypothetical: the plan reaches this script
# through `gh api … --jq .body`, and an issue body authored in GitHub's own web editor is CRLF. A
# surviving carriage return rides on the LAST item of every `**Files:**` line, defeats the trailing
# punctuation strip below, and reports that path MISSING with a diagnostic that looks identical to
# the path it is complaining about — the worst possible spelling of a false stale.
trim() {
  local s="${1-}"
  while :; do case "$s" in ' '*|$'\t'*|$'\r'*) s=${s#?} ;; *) break ;; esac; done
  while :; do case "$s" in *' '|*$'\t'|*$'\r') s=${s%?} ;; *) break ;; esac; done
  printf '%s' "$s"
}

DIR="."
BASE="origin/main"
PLAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C) [ $# -ge 2 ] || die2 "-C needs a directory"; DIR="$2"; shift 2 ;;
    -C*) DIR="${1#-C}"; shift ;;
    --base) [ $# -ge 2 ] || die2 "--base needs a ref"; BASE="$2"; shift 2 ;;
    --base=*) BASE="${1#--base=}"; shift ;;
    --) shift ;;
    -*) die2 "unknown option '$1'" ;;
    *)
      [ -z "$PLAN" ] || die2 "more than one plan file given ('$PLAN' and '$1')"
      PLAN="$1"; shift ;;
  esac
done

[ -n "$PLAN" ] || die2 "no plan file given — usage: plan-freshness.sh [-C <dir>] [--base <ref>] <plan.md>"
[ -r "$PLAN" ] || die2 "cannot read '$PLAN'"
# Load-bearing, exactly as in the locate recipe this runs after: a failed or rate-limited fetch
# leaves an EMPTY plan file, and an empty file has no `### Task` and no `**Files:**` line — it
# would sail through as "nothing to check, exit 0" and report a stale plan fresh.
[ -s "$PLAN" ] || die2 "'$PLAN' is empty — the plan fetch failed; do not read that as 'nothing stale'"

git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1 || die2 "'$DIR' is not a git repository"
git -C "$DIR" rev-parse --verify --quiet "$BASE^{commit}" > /dev/null 2>&1 \
  || die2 "base ref '$BASE' does not resolve in '$DIR' — fetch it rather than reading this as fresh"

SEP=$'\001'
# A control byte, distinct from SEP, planted in place of a `(new)`/`(new file)` aside so the marker
# rides along with the ONE item it was attached to, through the split on `; `/`, ` below — the aside
# itself is gone by the time an item is inspected (see the #433 note above `flush_files_field`).
NEWMARK=$'\002'
TASK=""
SEEN_TASK=0
MISSING=0
IN_FIELD=0
PAYLOAD=""

# A **Files:** field is prose meant to be soft-wrapped (`create-issue`'s own template writes it that
# way, and issue #412's own plan wrapped mid-parenthetical). Reading one physical line at a time made
# the verdict depend on where the source happened to wrap: the first line's now-unbalanced aside
# corrupted the comma-split into bogus fragments (a false MISSING), and the continuation line —
# starting with neither `### Task` nor `**Files:**` — matched no case at all and vanished with NO
# verdict at all (#419). So the field is ACCUMULATED across physical lines first, terminated by a
# blank line, a new `### Task`, a new `**Files:**`/`**Files**:` line, or end of file, and only then
# handed to the same parsing logic that always ran on a single line.
flush_files_field() {
  local payload item verb new_marker aside aside_lc
  payload=$(trim "$1")
  # A `**Files:**` line above the first `### Task` belongs to no task, so there is nothing to
  # report it against and nothing for Step 2 to re-anchor through. Skipping it is deliberate.
  [ "$SEEN_TASK" -eq 1 ] || return 0
  [ -n "$payload" ] || return 0

  # Parenthetical asides come out BEFORE the split, not after. `create-issue`'s own template writes
  # them — `modify \`Program.cs\` (DI registration)` — and an aside containing a comma would
  # otherwise be split down the middle into two paths that exist nowhere, reporting `MISSING` twice
  # and exit 5 on a plan that is perfectly fresh. That is not a cosmetic miscount: exit 5 routes
  # Step 2 into re-anchoring, and a path invented by the splitter re-anchors to nothing, which is
  # the "no usable plan" stop. A false stale costs the whole run.
  while :; do
    case "$payload" in
      *'('*')'*)
        aside=$(trim "${payload#*(}"); aside=${aside%%)*}; aside=$(trim "$aside")
        aside_lc=$(printf '%s' "$aside" | tr '[:upper:]' '[:lower:]')
        case "$aside_lc" in
          new|'new file') payload="${payload%%(*}${NEWMARK}${payload#*)}" ;;
          *)              payload="${payload%%(*}${payload#*)}" ;;
        esac
        ;;
      *) break ;;
    esac
  done

  payload=${payload//"; "/"$SEP"}
  payload=${payload//", "/"$SEP"}

  verb="modify"
  while [ -n "$payload" ]; do
    case "$payload" in
      *"$SEP"*) item=${payload%%"$SEP"*}; payload=${payload#*"$SEP"} ;;
      *) item="$payload"; payload="" ;;
    esac

    item=$(trim "$item")
    # Trailing sentence punctuation, then any aside the payload-level strip could not pair off.
    # GUARDED on the item holding BOTH parentheses: `${item%(*}` is a silent no-op when the `(` is
    # already gone, so an unguarded strip leaves a bare `)` glued to the path and then reports that
    # as MISSING.
    case "$item" in *.|*,|*';') item=${item%?} ;; esac
    case "$item" in *'('*')') item=$(trim "${item%(*}") ;; esac

    case "$item" in
      'create '*) verb=create; item=${item#create } ;;
      'modify '*) verb=modify; item=${item#modify } ;;
      'test '*)   verb=test;   item=${item#test } ;;
      'delete '*) verb=delete; item=${item#delete } ;;
    esac

    # Backticks are markup around the path, never part of it; a path is otherwise passed LITERALLY,
    # spaces and brackets included, because the split above is on `; ` and `, ` only.
    item=${item//'`'/}
    item=$(trim "$item")
    item=${item#./}

    # The marker planted above, if this item carried a `(new)`/`(new file)` aside. It rides on the
    # END of the item (the aside always followed the path), possibly after a trailing-punctuation
    # strip already removed a `.`/`,`/`;` that sat between the marker and the split point.
    new_marker=0
    case "$item" in
      *"$NEWMARK") item=${item%"$NEWMARK"}; item=$(trim "$item"); new_marker=1 ;;
    esac

    [ -n "$item" ] || continue

    # The closed no-file list — a task saying it touches nothing is not a path to resolve, in any
    # verb position. Exact spellings only: a case-insensitive or fuzzy match would risk swallowing a
    # real filename that happens to start with "none".
    case "$item" in
      'none expected'|'none expected.') continue ;;
    esac

    case "$verb" in
      create)
        printf 'SKIP create %s (Task %s)\n' "$item" "$TASK"
        ;;
      *)
        if [ "$new_marker" -eq 1 ]; then
          # A `(new)`/`(new file)` marker on any other verb reads exactly like `create`: the path
          # is EXPECTED absent, so existence is never checked — same as `create` never checking it,
          # including when the marker turns out to be stale (a path that already exists but is
          # still marked `(new)`). Printed with the item's own verb word, not "create", so the
          # reader still sees what the plan actually wrote (#433).
          printf 'SKIP %s %s (Task %s)\n' "$verb" "$item" "$TASK"
        elif git -C "$DIR" cat-file -e "$BASE:$item" 2>/dev/null; then
          printf 'OK %s %s (Task %s)\n' "$verb" "$item" "$TASK"
        else
          printf 'MISSING %s %s (Task %s)\n' "$verb" "$item" "$TASK"
          MISSING=$((MISSING + 1))
        fi
        ;;
    esac
  done
}

while IFS= read -r line || [ -n "$line" ]; do
  line=$(trim "$line")
  case "$line" in
    '### Task '*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; IN_FIELD=0; PAYLOAD=""; fi
      rest=${line#'### Task '}
      num=${rest%%[!0-9]*}
      [ -n "$num" ] && TASK="$num" || TASK="?"
      SEEN_TASK=1
      continue
      ;;
    # Both spellings of the bold marker. A `**Files**:` line matching nothing would report its whole
    # task fresh without resolving a single path — a silent un-gating, which is the failure shape
    # this script exists to remove rather than reproduce one line further in. Starting a new field
    # flushes whatever field was already accumulating (a malformed plan with two `**Files:**` lines
    # under one task reads as two separate fields, never a merge of both).
    '**Files:**'*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; fi
      PAYLOAD=$(trim "${line#'**Files:**'}")
      IN_FIELD=1
      continue
      ;;
    '**Files**:'*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; fi
      PAYLOAD=$(trim "${line#'**Files**:'}")
      IN_FIELD=1
      continue
      ;;
    '')
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; IN_FIELD=0; PAYLOAD=""; fi
      continue
      ;;
    # Any OTHER bold-labelled field under the same task — `**Interfaces:**` is the one every plan
    # carries (plan-shape.md's template), always separated from `**Files:**` by a blank line in
    # every fixture and every real issue plan this repo has — but nothing upstream enforces that
    # blank line, and swallowing it as a continuation would corrupt the Files field with prose that
    # was never part of it (code review, #419). Flush and ignore it, exactly as a plain prose line
    # was always ignored before this field ever started accumulating.
    '**'*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; IN_FIELD=0; PAYLOAD=""; fi
      continue
      ;;
    *)
      # A continuation line of the field currently accumulating; joined with a single space, trimmed
      # like every other line. Outside a field, an ordinary prose line — ignored, as before.
      [ "$IN_FIELD" -eq 1 ] && PAYLOAD="$PAYLOAD $line"
      continue
      ;;
  esac
done < "$PLAN"
[ "$IN_FIELD" -eq 1 ] && flush_files_field "$PAYLOAD"

# No `### Task` anywhere is not "a fresh plan"; it is a file that is not a plan. Exit 2 — the
# no-verdict code — so a caller cannot read the silence as an all-clear.
[ "$SEEN_TASK" -eq 1 ] || die2 "no '### Task' heading in '$PLAN' — this is not an implementation plan"

if [ "$MISSING" -gt 0 ]; then
  echo "plan-freshness: $MISSING path(s) named by the plan do not exist at $BASE — the plan is STALE." >&2
  echo "                Re-anchor each through its task's '**Interfaces:**' line (SKILL.md Step 2)," >&2
  echo "                or stop: a path that cannot be re-anchored is 'no usable plan' for that task." >&2
  exit 5
fi
