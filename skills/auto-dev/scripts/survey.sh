#!/usr/bin/env bash
# auto-dev survey — one-shot eligible-issue queue for Step 2 and the every-~5-merges re-survey.
#
# Why this exists: the survey (list issues → check each for a plan → classify effort →
# drop manual-QA → order small-before-medium) is a deterministic sequence the supervisor
# otherwise re-reasons from natural language every few merges. One `gh issue list` that
# fetches bodies, then jq does plan-detection + effort/eligibility classification — so the
# supervisor reads a ready-made, ordered queue instead of re-deriving it (fewer turns =
# less per-turn cache re-read, the dominant cost). The ONE judgment left to the model is
# area-tagging for conflict-avoidance, which is fuzzy — do that on the QUEUE rows below.
#
# Output, one row per issue, already ordered (smallest effort tier first, then the issues that
# unblock others, then by number):
#   QUEUE  #N  effort  plan=true  qa=false  deps=-  [labels]  title   ← eligible, area-tag + dispatch
#   HOLD   #N  ...                                                    ← tier past the second, unclassified, or held by a dependency edge
#   SKIP   #N  ...                                                    ← no plan, or manual-QA only
#
# The `deps=` column is the frontier (#317). The fleet may only dispatch the frontier — open, no
# OPEN blockers, not a tracking parent, unassigned — and every held row names which of those it
# failed: `deps=-` (nothing) · `deps=blocked_by=#12,#15` · `deps=parent(3)` · `deps=assigned` ·
# `deps=blocking=#20` (informational, and eligible: it sorts first inside its tier, because every
# slot spent elsewhere first leaves its blockees waiting). Without this the survey would QUEUE a
# blocked child ahead of its blocker — the worker builds against an interface that does not exist
# yet — and QUEUE a tracking parent, whose body is a list of children, not a plan to execute.
#
# Then ONE trailing summary row — the unplanned tail (#312):
#   SEED   <count>  waiting for a seed: #a #b            ← or `SEED  0  -` when nothing is waiting
# An unplanned backlog and a drained one are indistinguishable from the rows above alone: both just
# produce a short QUEUE. The count is every issue with plan=false and qa=false, in ANY bucket — a
# raw issue filed from the GitHub UI carries no effort: label either, so it tiers to 999 and lands
# in HOLD rather than SKIP, and a SKIP-only count would miss exactly the issues `create-issue
# --seed #N` was added to plan. Manual-QA issues are excluded: seeding one yields a plan no headless
# worker may execute. The supervisor REPORTS this line and never seeds on its own — seeding is a
# plan somebody has to own.
#
# Usage: scripts/survey.sh — the manifest lookup below resolves the repo's git toplevel itself
# (same convention as skills/setup-repo/scripts/repo-setup.sh), so it is correct from any
# subdirectory, not only the repo root.
#
# Effort tiering reads the ORDERED effort: vocabulary from this repo's own manifest
# (.github/repo-setup.yml, falling back to the kit's shipped templates/repo-setup.yml) instead of
# assuming a hardcoded single-letter spelling (#213). The previous `tier` matched a bare
# uppercase S/M/L against the label text — which never matches this repo's own word-spelled
# `effort: small`/`medium`/`large` labels, so every issue fell to tier 4 (HOLD) and an eligible
# backlog looked like a drained one. Ranking against the manifest's declared order works for
# either spelling, and stays correct if the vocabulary ever changes, because there is exactly one
# place — the manifest — that declares it.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd -P)"
PARSER="$KIT_ROOT/skills/setup-repo/scripts/parse-manifest.py"
# Resolved against the TARGET repo's toplevel, not the raw CWD — repo-setup.sh does the same
# (cd to `git rev-parse --show-toplevel` before checking this same relative path) so that a caller
# working from a subdirectory (a worktree, a nested skill invocation) still finds the repo-local
# manifest instead of silently missing it. Outside any git repo (or a bare one), `show-toplevel`
# fails and this falls back to the plain CWD, which is what it was before.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
REPO_LOCAL_MANIFEST="$REPO_ROOT/.github/repo-setup.yml"
DEFAULT_MANIFEST="$KIT_ROOT/templates/repo-setup.yml"

# Precedence matches repo-setup.sh: the target repo's own manifest first, then the kit's shipped
# default — never a hand-rolled YAML read here, so the taxonomy has one parser (#213 plan Task 1).
if [ -r "$REPO_LOCAL_MANIFEST" ]; then
  MANIFEST="$REPO_LOCAL_MANIFEST"
elif [ -r "$DEFAULT_MANIFEST" ]; then
  MANIFEST="$DEFAULT_MANIFEST"
else
  MANIFEST=""
fi

VOCAB_JSON=""
PARSER_RC=0
PARSER_STDERR=""
# Per-stage exit statuses of the awk|grep|sed|tr|jq extraction pipeline below (printf counts as
# stage 0), and whether any of them amounts to a real tool failure. Initialized here so both are
# always safe to reference under `set -u`, even on every path that never reaches the pipeline at
# all (no manifest, parser missing, parser died).
VOCAB_PIPE_RC=(0 0 0 0 0 0)
VOCAB_PIPE_FAILED=0
# Distinct from PARSER_RC ("the parser's actual exit status"): PARSER_ATTEMPTED only records
# whether the invocation block below ever ran at all. A missing/unreadable $PARSER makes
# `[ -r "$PARSER" ]` false, so the whole block — PARSER_RC included — is skipped, and PARSER_RC
# stays at its 0 default. Without this flag that reads as "the parser ran fine and declared
# nothing", the exact wrong diagnosis for "the parser file itself is gone" (#239).
PARSER_ATTEMPTED=0
if [ -n "$MANIFEST" ] && [ -r "$PARSER" ]; then
  PARSER_ATTEMPTED=1
  # The parser runs on its own here — not piped straight into awk/grep/sed/tr/jq like the rest of
  # this block — so its exit status can be told apart from the downstream tools' (`grep -i
  # '^effort:'` legitimately exits 1 when the manifest declares no effort: labels, and under
  # `pipefail` that would be indistinguishable from the parser itself dying). Discarding its
  # stderr with `2>/dev/null`, as before, made a die() on a label with nothing to do with the
  # effort: axis collapse into the exact same empty VOCAB_JSON as "no effort: labels found" or "no
  # readable manifest" — reopening #213's mis-tiering through a path #213 never exercised (#230).
  PARSER_ERR_FILE=""
  if PARSER_ERR_FILE="$(mktemp 2>/dev/null)"; then
    trap 'rm -f "$PARSER_ERR_FILE"' EXIT
  fi
  if PARSER_STDOUT="$(python3 "$PARSER" "$MANIFEST" 2>"${PARSER_ERR_FILE:-/dev/null}")"; then
    PARSER_RC=0
  else
    PARSER_RC=$?
  fi
  # Three distinct outcomes, not one: "mktemp itself failed" (stderr was never captured at all),
  # "captured but the file can't be read back" and "captured and genuinely empty" are different
  # facts about what happened, and collapsing them into one string would tell an operator "the
  # parser printed nothing" when the truth might be "we don't know what it printed".
  if [ -z "$PARSER_ERR_FILE" ]; then
    PARSER_STDERR="<stderr could not be captured: mktemp failed>"
  elif PARSER_STDERR="$(cat -- "$PARSER_ERR_FILE" 2>/dev/null)"; then
    [ -n "$PARSER_STDERR" ] || PARSER_STDERR="<parser printed nothing on stderr>"
  else
    PARSER_STDERR="<stderr was captured but could not be read back from $PARSER_ERR_FILE>"
  fi

  if [ "$PARSER_RC" -eq 0 ]; then
    # A command substitution (`VAR=$(pipeline)`) runs the pipeline in a subshell, so PIPESTATUS
    # captured after it reflects only the assignment itself, never the pipeline's per-stage exit
    # codes (measured: `X=$(false | true); echo "${PIPESTATUS[@]}"` prints a single "0"). Routing
    # the pipeline's stdout to a temp file instead — and wrapping it in `if` so a pipefail exit
    # doesn't trip `set -e` before PIPESTATUS can be read — keeps the per-stage codes visible.
    VOCAB_TMP=""
    if VOCAB_TMP="$(mktemp 2>/dev/null)"; then
      trap 'rm -f "$PARSER_ERR_FILE" "$VOCAB_TMP"' EXIT
      if printf '%s\n' "$PARSER_STDOUT" \
           | awk -F'\t' '$1 == "L" { print $2 }' \
           | grep -i '^effort:' \
           | sed -E 's/^[Ee][Ff][Ff][Oo][Rr][Tt]:[[:space:]]*//' \
           | tr '[:upper:]' '[:lower:]' \
           | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null > "$VOCAB_TMP"; then
        VOCAB_PIPE_RC=("${PIPESTATUS[@]}")
      else
        VOCAB_PIPE_RC=("${PIPESTATUS[@]}")
      fi
      # `|| VOCAB_PIPE_FAILED=1`: reading the pipeline's own output back can fail even when every
      # stage above exited 0 (the temp file vanished, a permissions race, a read error) — that is
      # itself the extraction machinery breaking, not "no effort: labels found", and must be
      # counted the same way a nonzero per-stage exit is below.
      VOCAB_JSON="$(cat -- "$VOCAB_TMP" 2>/dev/null)" || { VOCAB_JSON=""; VOCAB_PIPE_FAILED=1; }

      # Stage 2 is `grep -i '^effort:'`, which legitimately exits 1 when the manifest declares no
      # effort: labels at all — an empty match, not a tool failure — so only a grep exit ABOVE 1
      # (a real grep error) counts there. Every other stage (printf, awk, sed, tr, jq) has no
      # "expected nonzero" case: any nonzero exit from one of those is the pipeline actually
      # breaking, which is what this issue's stub-jq reproduction exercises.
      if [ "${VOCAB_PIPE_RC[2]}" -gt 1 ]; then
        VOCAB_PIPE_FAILED=1
      fi
      for i in 0 1 3 4 5; do
        [ "${VOCAB_PIPE_RC[$i]}" -ne 0 ] && VOCAB_PIPE_FAILED=1
      done
    else
      # mktemp itself failing (full/unwritable $TMPDIR) means the extraction pipeline never even
      # ran — a real tool failure, same as a nonzero per-stage exit, not "no effort: labels found".
      VOCAB_PIPE_FAILED=1
    fi
  fi
fi

# Degraded fallback: the manifest is missing or unreadable, the parser died reading it, or it
# parsed fine but declares no effort: axis at all. Case-insensitive whole-word matching against
# the vocabulary every shipped manifest actually uses today is a documented degraded path, not a
# silent reproduction of the bug this replaces — it still classifies word-spelled labels
# correctly, it just cannot see a vocabulary it was never told about.
#
# "[]" is jq's exact, single-line rendering of an empty array (verified: `printf '' | jq -R -s
# 'split("\n") | map(select(length > 0))'` prints exactly that), so a plain string compare catches
# the empty-vocabulary case without spawning a second jq just to ask it the length — on every
# normal run, not only the degraded one, since a non-empty pipeline result is never the empty
# bash string either.
#
# `|| [ "$VOCAB_PIPE_FAILED" -eq 1 ]` matters on its own, independent of VOCAB_JSON's content: a
# pipe stage can die AFTER already flushing some of its input downstream (sed killed mid-stream,
# a transient I/O error) — jq then slurps whatever reached it and happily emits a well-formed,
# non-empty, non-"[]" array from truncated input. Without this clause a real pipeline failure with
# partial output would silently pass through as the (wrong, truncated) vocabulary, with neither a
# warning nor a revert to the safe small/medium/large default — the exact silent corruption this
# fix's own instrumentation exists to catch.
if [ -z "$VOCAB_JSON" ] || [ "$VOCAB_JSON" = "[]" ] || [ "$VOCAB_PIPE_FAILED" -eq 1 ]; then
  if [ "$PARSER_RC" -ne 0 ]; then
    echo "survey.sh: parse-manifest.py failed (exit $PARSER_RC) reading $MANIFEST — falling back to small/medium/large; the manifest's effort: axis could not be confirmed. Parser said: $PARSER_STDERR" >&2
  elif [ "$PARSER_ATTEMPTED" -eq 0 ] && [ -n "$MANIFEST" ]; then
    echo "survey.sh: parser $PARSER is missing or unreadable — cannot confirm $MANIFEST's effort: axis — falling back to small/medium/large" >&2
  elif [ "$PARSER_ATTEMPTED" -eq 1 ] && [ "$VOCAB_PIPE_FAILED" -eq 1 ]; then
    echo "survey.sh: parse-manifest.py ran successfully, but the vocabulary-extraction pipeline that reads its output failed (per-stage exit statuses: ${VOCAB_PIPE_RC[*]}) — cannot confirm $MANIFEST's effort: axis — falling back to small/medium/large" >&2
  elif [ -n "$MANIFEST" ]; then
    echo "survey.sh: no effort: labels found in $MANIFEST — falling back to small/medium/large" >&2
  else
    echo "survey.sh: no readable repo-setup manifest — falling back to small/medium/large" >&2
  fi
  VOCAB_JSON='["small","medium","large"]'
fi

gh issue list --state open --limit 300 \
  --json number,title,labels,body,blockedBy,blocking,subIssues,assignees \
  | jq -r --argjson vocab "$VOCAB_JSON" '
    def eff:       (.labels | map(.name) | map(select(startswith("effort:"))) | (.[0] // "effort: ?"));
    def haveplan:  ((.body  // "") | test("Implementation plan|### Task|- \\[ \\]"));
    def manualqa:  ((.title // "") | test("visually|verify by hand|manual QA|by hand"; "i"));
    # Dependency edges (#317). `gh issue list --json blockedBy,blocking,subIssues` serves GraphQL
    # CONNECTIONS — {"nodes":[…],"totalCount":N} — measured on gh 2.98.0, while this repo'"'"'s own
    # sketch of these fields assumed plain arrays. Reading only one shape would silently degrade the
    # other to "no edges", which IS the bug: a blocked child dispatched ahead of its blocker. So
    # accept both, and let anything else (null, a field an older gh cannot serve, a fixture predating
    # this change) fall through to [] rather than erroring the whole survey.
    def numlist:
      (if   type == "object" then (.nodes // [])
       elif type == "array"  then .
       else [] end)
      | map(if type == "object" then (.number // empty) elif type == "number" then . else empty end);
    # The prose fallback create-issue writes when the dependencies API is unavailable. Anchored to
    # the start of a line — `(?m)` is what makes `^` mean that in jq'"'"'s Oniguruma, which anchors to
    # the start of the whole STRING without it (measured) — so a "**Blocked by:** #5"
    # quoted mid-sentence does not hold an issue. It can only ever ADD a blocker, never clear one —
    # see SKILL.md Step 2: the worst a hostile body line can do is delay its own issue.
    def bodyblockers:
      ((.body // "")
       | [ scan("(?m)^\\**Blocked by:\\**\\s*((?:#[0-9]+(?:,\\s*)?)+)")
           | .[0] | scan("#([0-9]+)") | .[0] | tonumber ]);
    # Rank the effort token against the vocabulary order (index 0 = tier 1) rather than testing
    # for a bare letter. A token the vocabulary does not declare — no effort: label at all, or a
    # spelling outside it — gets a sentinel past any real tier, same as the original "else 4": a
    # fixed 999 rather than ($vocab | length) + 1, so an unclassified issue still lands past the
    # hardcoded ">2" HOLD threshold below even for a manifest declaring only one or two effort
    # tiers, where length+1 could land AT OR BELOW 2 and read as eligible.
    def tier:
      (eff | sub("^effort:\\s*"; "") | ascii_downcase) as $tok
      | ($vocab | index($tok)) as $idx
      | if $idx == null then 999 else $idx + 1 end;
    # Every edge is filtered against the numbers THIS call returned — the open set. A blocker that
    # is closed does not block, and neither does one that never existed. Two known consequences,
    # both deliberate: an edge pointing outside the --limit 300 window reads as closed (the existing
    # window'"'"'s limitation, not a new one), and a blockee that has already been closed stops
    # promoting its blocker, which is exactly right — there is nothing left to unblock.
    (map(.number)) as $open
    | def inopen: map(select(. as $b | $open | index($b)));
      map({n:.number, title:.title, e:eff, plan:haveplan, qa:manualqa,
           labels:(.labels|map(.name)|join(",")), t:tier,
           blockers: ((((.blockedBy // []) | numlist) + bodyblockers) | unique | inopen),
           blocking: ((((.blocking  // []) | numlist)                | unique | inopen)),
           subs:     (((.subIssues  // []) | numlist) | length),
           assigned: (((.assignees  // []) | length) > 0)})
    | map(. + {deps:
        (if   (.subs > 0)              then "parent(\(.subs))"
         elif ((.blockers|length) > 0) then "blocked_by=" + ([.blockers[] | "#\(.)"] | join(","))
         elif .assigned                then "assigned"
         elif ((.blocking|length) > 0) then "blocking="   + ([.blocking[] | "#\(.)"] | join(","))
         else                               "-"
         end)})
    # Eligible-and-unblocking first inside a tier: dispatching a blocker early converts its blockees
    # into frontier the next re-survey can use, where any other order leaves them — and the slots
    # they would fill — waiting.
    | sort_by(.t, -(.blocking|length), .n)
    | . as $rows
    | (
        $rows[]
        # The three dependency holds come FIRST, ahead of the tier test: a blocked child, a tracking
        # parent and a claimed issue are not dispatchable at any effort tier, and the deps= column
        # says which one it was.
        | (if   (.subs > 0)                   then "HOLD "
           elif ((.blockers|length) > 0)      then "HOLD "
           elif .assigned                     then "HOLD "
           elif (.t > 2)                      then "HOLD "
           elif (.plan and (.qa | not))       then "QUEUE"
           else                                    "SKIP "
           end) as $bucket
        | "\($bucket)\t#\(.n)\t\(.e)\tplan=\(.plan)\tqa=\(.qa)\tdeps=\(.deps)\t[\(.labels)]\t\(.title)"
      ),
      # The unplanned tail, printed LAST so it reads as a summary of the rows above (and so this
      # addition stays append-only against the other in-flight changes to this program). Listed by
      # issue number rather than in the tier order above: a HOLD row sorts to the end by tier, and
      # the supervisor pastes these straight into `/create-issue --seed #N`.
      (
        [ $rows[] | select((.plan | not) and (.qa | not)) ] | sort_by(.n) as $seed
        | if ($seed | length) == 0
          then "SEED\t0\t-"
          else "SEED\t\($seed | length)\twaiting for a seed: " + ([ $seed[] | "#\(.n)" ] | join(" "))
          end
      )
  '
