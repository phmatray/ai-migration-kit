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
# Output, one row per issue, already ordered (smallest effort tier first, then by number):
#   QUEUE  #N  effort  plan=true  qa=false  [labels]  title   ← eligible, area-tag + dispatch
#   HOLD   #N  ...                                            ← tier past the second, or unclassified
#   SKIP   #N  ...                                            ← no plan, or manual-QA only
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
if [ -n "$MANIFEST" ] && [ -r "$PARSER" ]; then
  VOCAB_JSON="$(python3 "$PARSER" "$MANIFEST" 2>/dev/null \
    | awk -F'\t' '$1 == "L" { print $2 }' \
    | grep -i '^effort:' \
    | sed -E 's/^[Ee][Ff][Ff][Oo][Rr][Tt]:[[:space:]]*//' \
    | tr '[:upper:]' '[:lower:]' \
    | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)" || VOCAB_JSON=""
fi

# Degraded fallback: the manifest is missing, unreadable, or declares no effort: axis at all.
# Case-insensitive whole-word matching against the vocabulary every shipped manifest actually
# uses today is a documented degraded path, not a silent reproduction of the bug this replaces —
# it still classifies word-spelled labels correctly, it just cannot see a vocabulary it was never
# told about.
#
# "[]" is jq's exact, single-line rendering of an empty array (verified: `printf '' | jq -R -s
# 'split("\n") | map(select(length > 0))'` prints exactly that), so a plain string compare catches
# the empty-vocabulary case without spawning a second jq just to ask it the length — on every
# normal run, not only the degraded one, since a non-empty pipeline result is never the empty
# bash string either.
if [ -z "$VOCAB_JSON" ] || [ "$VOCAB_JSON" = "[]" ]; then
  if [ -n "$MANIFEST" ]; then
    echo "survey.sh: no effort: labels found in $MANIFEST — falling back to small/medium/large" >&2
  else
    echo "survey.sh: no readable repo-setup manifest — falling back to small/medium/large" >&2
  fi
  VOCAB_JSON='["small","medium","large"]'
fi

gh issue list --state open --limit 300 \
  --json number,title,labels,body \
  | jq -r --argjson vocab "$VOCAB_JSON" '
    def eff:       (.labels | map(.name) | map(select(startswith("effort:"))) | (.[0] // "effort: ?"));
    def haveplan:  ((.body  // "") | test("Implementation plan|### Task|- \\[ \\]"));
    def manualqa:  ((.title // "") | test("visually|verify by hand|manual QA|by hand"; "i"));
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
    map({n:.number, title:.title, e:eff, plan:haveplan, qa:manualqa,
         labels:(.labels|map(.name)|join(",")), t:tier})
    | sort_by(.t, .n)
    | .[]
    | (if   (.t > 2)                      then "HOLD "
       elif (.plan and (.qa | not))       then "QUEUE"
       else                                    "SKIP "
       end) as $bucket
    | "\($bucket)\t#\(.n)\t\(.e)\tplan=\(.plan)\tqa=\(.qa)\t[\(.labels)]\t\(.title)"
  '
