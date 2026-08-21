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
      VOCAB_JSON="$(cat -- "$VOCAB_TMP" 2>/dev/null)" || VOCAB_JSON=""

      # Stage 2 is `grep -i '^effort:'`, which legitimately exits 1 when the manifest declares no
      # effort: labels at all — an empty match, not a tool failure — so only a grep exit ABOVE 1
      # (a real grep error) counts there. Every other stage (printf, awk, sed, tr, jq) has no
      # "expected nonzero" case: any nonzero exit from one of those is the pipeline actually
      # breaking, which is what this issue's stub-jq reproduction exercises.
      i=0
      for rc in "${VOCAB_PIPE_RC[@]}"; do
        if [ "$i" -eq 2 ]; then
          [ "$rc" -gt 1 ] && VOCAB_PIPE_FAILED=1
        else
          [ "$rc" -ne 0 ] && VOCAB_PIPE_FAILED=1
        fi
        i=$((i + 1))
      done
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
if [ -z "$VOCAB_JSON" ] || [ "$VOCAB_JSON" = "[]" ]; then
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
