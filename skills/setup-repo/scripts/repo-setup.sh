#!/usr/bin/env bash
# repo-setup.sh — bring a repository to the configuration the lifecycle skills assume (#192).
#
# get-repo-profile's repo-profile.sh answers "what IS this repo?" and both of its verbs read.
# There was no verb answering "make this repo what the skills need", so a probe that found no
# priority:/effort:/area: axis and no .github/ISSUE_TEMPLATE/ could only print `TODO: <hint>` —
# correct for a fact it cannot read, wrong for a configuration the repo does not HAVE. This script
# is the missing half.
#
#   plan [dir]     Diff the desired state against the live repository and print the delta. Writes
#                  NOTHING, so it is safe against a repo you only read. Exit 1 when drift remains,
#                  which makes it usable as a CI drift gate.
#
#   apply [dir]    Converge it. Idempotent: a second run issues no writes.
#
# Options: --manifest <path>   desired state (default: the target repo's .github/repo-setup.yml,
#                              else the kit's templates/repo-setup.yml)
#          --prune             also DELETE live labels the manifest does not declare. Never the
#                              default: a repo that already runs P1/P2 must not have its taxonomy
#                              renamed out from under it.
#
# Exit codes:
#   0  converged (plan) / applied cleanly (apply)
#   1  drift found (plan only)
#   2  bad usage, or a manifest that cannot be read or parsed
#   3  partially applied — a surface was refused (no admin scope, no gh auth). The report names it.
#   4  not inside a git repository  (the same meaning repo-profile.sh gives 4, deliberately)
#
# No `set -e`: this script's job is to keep going when ONE surface refuses and report the rest,
# which errexit would turn into an abort. Failures are checked at each call site instead — the
# same reasoning repo-profile.sh states for its own `set -uo pipefail`.
set -uo pipefail

# Resolved BEFORE the cd below: $0 can be relative, and cd-ing into the target repo breaks it.
# Kit root = three levels up from skills/setup-repo/scripts.
KIT_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd -P)"
PARSER="$KIT_ROOT/skills/setup-repo/scripts/parse-manifest.py"
FORMS_DIR="$KIT_ROOT/templates/issue-forms"
DEFAULT_MANIFEST="$KIT_ROOT/templates/repo-setup.yml"
REPO_LOCAL_MANIFEST=".github/repo-setup.yml"
FORMS_TARGET=".github/ISSUE_TEMPLATE"

USAGE="usage: repo-setup.sh {plan|apply} [dir] [--manifest <path>] [--prune]"

usage_err() { echo "ERR: $1" >&2; echo "$USAGE" >&2; exit 2; }

# ------------------------------------------------------------------------------ argument parsing

VERB="${1:-}"
[ $# -gt 0 ] && shift

DIR=""
MANIFEST=""
PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      # `[ $# -ge 2 ]` rather than a non-empty test on $2: `--manifest --prune` must be a usage
      # error, not a manifest literally named "--prune", and `--manifest` at end-of-args must not
      # silently become the default.
      [ $# -ge 2 ] || usage_err "--manifest needs a path"
      case "$2" in -*) usage_err "--manifest needs a path, got the option '$2'" ;; esac
      MANIFEST="$2"; shift 2 ;;
    --prune) PRUNE=1; shift ;;
    --) shift ;;
    -*) usage_err "unknown option '$1'" ;;
    *)
      [ -z "$DIR" ] || usage_err "unexpected extra argument '$1'"
      DIR="$1"; shift ;;
  esac
done

case "$VERB" in
  plan|apply) ;;
  "") usage_err "no verb given" ;;
  *)  usage_err "unknown verb '$VERB'" ;;
esac

# ------------------------------------------------------------------------------------ where am I

# An explicit --manifest is resolved against the CALLER's directory, before the cd below. Otherwise
# `repo-setup.sh plan ../other-repo --manifest my.yml` looks for my.yml inside other-repo — a path
# the caller never typed, and one that usually exists nowhere, so the run dies on exit 2 pointing at
# a file the operator did not ask for.
if [ -n "$MANIFEST" ]; then
  case "$MANIFEST" in
    /*|[A-Za-z]:[\\/]*) ;;                      # already absolute, POSIX or Windows drive form
    *) MANIFEST="$PWD/$MANIFEST" ;;
  esac
fi

[ -z "$DIR" ] && DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$DIR" 2>/dev/null || { echo "ERR: cannot cd to '$DIR'" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERR: not inside a git repository — nothing to configure." >&2; exit 4; }

# ------------------------------------------------------------------------------- desired state

# Precedence: an explicit --manifest always wins; then the target repo's own copy, so a consumer's
# edits survive a kit upgrade; then the shipped default.
if [ -z "$MANIFEST" ]; then
  if [ -r "$REPO_LOCAL_MANIFEST" ]; then
    MANIFEST="$REPO_LOCAL_MANIFEST"
  else
    MANIFEST="$DEFAULT_MANIFEST"
  fi
fi

[ -r "$MANIFEST" ] || { echo "ERR: cannot read the manifest '$MANIFEST'" >&2; exit 2; }
[ -r "$PARSER" ] || { echo "ERR: parser missing at '$PARSER'" >&2; exit 2; }

# The parser exits 2 and explains on stderr for every refusal, so its status is carried straight
# through rather than restated. Captured into a variable because the diff below walks it twice.
WORKDIR="$(mktemp -d 2>/dev/null)" || { echo "ERR: cannot create a temp directory" >&2; exit 2; }
# `local rc=$?` FIRST, always: anything above it overwrites the status being reported, which turns
# a failing run into a silent success. Same invariant tests/_lib.sh states for its own handler.
cleanup() { local rc=$?; rm -rf "$WORKDIR"; return $rc; }
trap cleanup EXIT

DESIRED="$WORKDIR/desired.tsv"
# The parser exits 2 and explains on stderr for every refusal, so its status is carried straight
# through rather than restated.
python3 "$PARSER" "$MANIFEST" > "$DESIRED" || exit 2

# --------------------------------------------------------------------------------- live state

DRIFT=0            # +ADD / ~EDIT items — what `plan` exits 1 for
REFUSED=0          # surfaces that could not be read or written — exit 3, and named in the report
DELTA="$WORKDIR/delta.tsv"
: > "$DELTA"

# Every report line goes through here so the column widths cannot drift between surfaces, and the
# machine-readable delta cannot fall out of step with what the human was shown: one call writes
# both. `apply` re-reads $DELTA rather than re-deriving the diff.
emit() {
  printf '%-7s %-8s %s\n' "$1" "$2" "$3"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${4:-}" "${5:-}" "${6:-}" >> "$DELTA"
  case "$1" in
    "+ADD"|"~EDIT"|"-DEL") DRIFT=$((DRIFT + 1)) ;;
  esac
}

refuse() {
  printf '%-7s %-8s %s\n' "!REFUSED" "$1" "$2"
  REFUSED=$((REFUSED + 1))
}

# Labels no `--prune` may delete, however undeclared they look. Found by running `plan` against
# this kit's own repository: release-please owns `autorelease: pending` / `autorelease: tagged`,
# the repo profile says in as many words that they are never applied by hand — and a single
# `apply --prune` would have deleted both and broken the release pipeline. An opt-in flag whose
# documented use breaks the repo it ships from is not opt-in enough.
KEEP_FILE="$WORKDIR/prune-keep.txt"
awk -F'\t' '$1=="K" {print $2}' "$DESIRED" > "$KEEP_FILE"

is_kept() {
  local n="$1" pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # $pat is deliberately unquoted: these are globs, so `autorelease: *` covers both of them.
    case "$n" in $pat) return 0 ;; esac
  done < "$KEEP_FILE"
  return 1
}

GH_OK=1
command -v gh >/dev/null 2>&1 || GH_OK=0
[ "$GH_OK" = 1 ] && { gh auth status >/dev/null 2>&1 || GH_OK=0; }
command -v jq >/dev/null 2>&1 || { echo "ERR: jq is missing — it is a required prerequisite" >&2; exit 2; }

SLUG=""
if [ "$GH_OK" = 1 ]; then
  SLUG="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty' 2>/dev/null)"
fi

LIVE_LABELS="$WORKDIR/live-labels.tsv"
: > "$LIVE_LABELS"
LABELS_READABLE=0
LABEL_LIMIT=200
if [ "$GH_OK" = 0 ]; then
  refuse "labels" "gh is unavailable or unauthenticated — the label axis was not read"
elif gh label list --limit "$LABEL_LIMIT" --json name,color,description > "$WORKDIR/labels.json" 2>/dev/null; then
  if jq -r '.[] | "L\t" + .name + "\t" + ((.color // "") | ascii_downcase) + "\t" + (.description // "")' \
       "$WORKDIR/labels.json" > "$LIVE_LABELS" 2>/dev/null; then
    # A full page is indistinguishable from a truncated one, and a truncated read makes every
    # invisible label look absent: `plan` would report +ADD for labels that already exist and
    # `apply` would then fail on each. Refuse rather than diff against a list that may be partial.
    live_count=$(wc -l < "$LIVE_LABELS")
    if [ "$live_count" -ge "$LABEL_LIMIT" ]; then
      refuse "labels" "gh returned the full page of $LABEL_LIMIT labels — the list may be truncated, so the diff cannot be trusted"
    else
      LABELS_READABLE=1
    fi
  else
    refuse "labels" "gh returned a label payload jq could not read"
  fi
else
  refuse "labels" "gh label list failed — no access to this repository's labels"
fi

LIVE_SETTINGS="$WORKDIR/live-settings.json"
SETTINGS_READABLE=0
if [ "$GH_OK" = 0 ] || [ -z "$SLUG" ]; then
  [ "$GH_OK" = 1 ] && refuse "settings" "the repository slug is unreadable — settings were not read"
elif gh api "repos/$SLUG" > "$LIVE_SETTINGS" 2>/dev/null; then
  SETTINGS_READABLE=1
else
  refuse "settings" "gh api repos/$SLUG failed — settings were not read"
fi

echo "manifest: $MANIFEST"
[ -n "$SLUG" ] && echo "repo:     $SLUG"
echo ""

# ------------------------------------------------------------------------------------- the diff

# Read from a file rather than a pipe: a `while … done < <(…)` or `… | while` runs the body in a
# SUBSHELL, where DRIFT and REFUSED would be incremented on a copy and every count would come back
# zero — a green report over a repo full of drift.
while IFS="$(printf '\t')" read -r kind f1 f2 f3; do
  case "$kind" in
    L)
      name="$f1"; color="$f2"; desc="$f3"
      # A <…> name is the manifest saying "an axis belongs here and nobody has filled it in".
      # Reported on every run so it stays visible, but never drift: a repo that has deliberately
      # not filled it must still be able to reach a converged plan.
      case "$name" in
        *"<"*">"*)
          emit "!TODO" "label" "$name — placeholder, fill it in $MANIFEST"
          continue ;;
      esac
      [ "$LABELS_READABLE" = 1 ] || continue
      live="$(awk -F'\t' -v n="$name" '$1=="L" && $2==n {print $3 "\t" $4; exit}' "$LIVE_LABELS")"
      if [ -z "$live" ]; then
        emit "+ADD" "label" "$name ($color)" "$name" "$color" "$desc"
      else
        live_color="${live%%	*}"
        live_desc="${live#*	}"
        if [ "$live_color" = "$color" ] && [ "$live_desc" = "$desc" ]; then
          emit "=OK" "label" "$name"
        else
          emit "~EDIT" "label" "$name — $live_color/$live_desc -> $color/$desc" "$name" "$color" "$desc"
        fi
      fi
      ;;
    T)
      name="$f1"
      if [ ! -r "$FORMS_DIR/$name" ]; then
        refuse "forms" "$name is declared but the kit ships no templates/issue-forms/$name"
      elif [ -e "$FORMS_TARGET/$name" ]; then
        # Never clobber: a consumer's tuned form outranks the kit's default.
        emit "!SKIP" "form" "$name — already present, left as is"
      else
        emit "+ADD" "form" "$name" "$name"
      fi
      ;;
    S)
      key="$f1"; want="$f2"
      [ "$SETTINGS_READABLE" = 1 ] || continue
      have="$(jq -r --arg k "$key" 'if has($k) then (.[$k] | tostring) else "" end' "$LIVE_SETTINGS" 2>/dev/null)"
      if [ "$have" = "$want" ]; then
        emit "=OK" "setting" "$key: $want"
      else
        emit "~EDIT" "setting" "$key: ${have:-<absent>} -> $want" "$key" "$want"
      fi
      ;;
  esac
done < "$DESIRED"

# A live label the manifest does not declare is REPORTED and kept. Deleting by default would let a
# kit upgrade quietly rename somebody's taxonomy out from under them.
if [ "$LABELS_READABLE" = 1 ]; then
  while IFS="$(printf '\t')" read -r kind name _rest; do
    [ "$kind" = "L" ] || continue
    [ -n "$name" ] || continue
    if ! awk -F'\t' -v n="$name" '$1=="L" && $2==n {found=1} END {exit !found}' "$DESIRED"; then
      if [ "$PRUNE" = 1 ] && is_kept "$name"; then
        emit "!KEEP" "label" "$name — undeclared but protected by pruneKeep, not deleted"
      elif [ "$PRUNE" = 1 ]; then
        emit "-DEL" "label" "$name — undeclared, queued for deletion (--prune)" "$name" "" ""
      else
        emit "!EXTRA" "label" "$name — live but not declared (kept; --prune would delete it)"
      fi
    fi
  done < "$LIVE_LABELS"
fi

echo ""

# --------------------------------------------------------------------------------------- verdict

if [ "$VERB" = "plan" ]; then
  if [ "$REFUSED" -gt 0 ]; then
    echo "plan: $DRIFT item(s) of drift, $REFUSED surface(s) unreadable — the report names them."
    exit 3
  fi
  if [ "$DRIFT" -gt 0 ]; then
    echo "plan: $DRIFT item(s) of drift. Run \`repo-setup.sh apply\` to converge."
    exit 1
  fi
  echo "plan: converged — nothing to do."
  exit 0
fi

# ----------------------------------------------------------------------------------- apply

# One pass over the delta the diff already computed, rather than a second derivation. Two
# derivations of the same decision drift, and a drifted copy of a gate is this repo's recurring
# failure (#141, #163) — here it would mean applying something the operator was never shown.
#
# Nothing below uses `&&` chaining across surfaces: one refusal must not skip the rest. That is
# what exit 3 is for, and it is the difference between "the settings needed admin and the labels
# are in place" and "nothing happened, and you get to guess why".
APPLIED=0
# Settings are batched into ONE PATCH rather than one call per key: GitHub applies them as a single
# object, and a per-key loop would leave a half-configured repo behind whenever the token ran out
# of scope midway. Declared before the loop so it survives it — the loop reads from a file, not a
# pipe, precisely so this stays in the parent shell.
SET_ARGS=()
SET_COUNT=0

while IFS="$(printf '\t')" read -r action kind f1 f2 f3; do
  case "$action" in
    "+ADD"|"~EDIT"|"-DEL") ;;
    *) continue ;;
  esac
  case "$kind" in
    label)
      [ -n "$f1" ] || continue
      if [ "$action" = "-DEL" ]; then
        if gh label delete "$f1" --yes >/dev/null 2>&1; then
          APPLIED=$((APPLIED + 1))
        else
          refuse "labels" "could not delete '$f1'"
        fi
      elif [ "$action" = "+ADD" ]; then
        if gh label create "$f1" --color "$f2" --description "$f3" >/dev/null 2>&1; then
          APPLIED=$((APPLIED + 1))
        else
          refuse "labels" "could not create '$f1' — check the token's scope on this repository"
        fi
      else
        if gh label edit "$f1" --color "$f2" --description "$f3" >/dev/null 2>&1; then
          APPLIED=$((APPLIED + 1))
        else
          refuse "labels" "could not edit '$f1' — check the token's scope on this repository"
        fi
      fi
      ;;
    form)
      [ -n "$f1" ] || continue
      # Only ever reached for +ADD: an existing form was already classified !SKIP by the diff, and
      # !SKIP is not in the action filter above. The never-clobber rule lives in one place.
      if mkdir -p "$FORMS_TARGET" 2>/dev/null && cp "$FORMS_DIR/$f1" "$FORMS_TARGET/$f1" 2>/dev/null; then
        APPLIED=$((APPLIED + 1))
      else
        refuse "forms" "could not write $FORMS_TARGET/$f1"
      fi
      ;;
    setting)
      [ -n "$f1" ] || continue
      SET_ARGS[${#SET_ARGS[@]}]="-F"
      SET_ARGS[${#SET_ARGS[@]}]="$f1=$f2"
      SET_COUNT=$((SET_COUNT + 1))
      ;;
  esac
done < "$DELTA"

if [ "$SET_COUNT" -gt 0 ]; then
  if [ "$GH_OK" = 0 ] || [ -z "$SLUG" ]; then
    refuse "settings" "$SET_COUNT setting(s) need gh and a repository slug — not applied"
  # `${arr[@]+"${arr[@]}"}` and not a bare "${arr[@]}": under `set -u`, bash 3.2 treats an empty
  # array expansion as an unbound variable and aborts. SET_COUNT > 0 means it is not empty here,
  # but the idiom is the one this file has to use everywhere, so it is used consistently.
  elif gh api -X PATCH "repos/$SLUG" ${SET_ARGS[@]+"${SET_ARGS[@]}"} >/dev/null 2>&1; then
    APPLIED=$((APPLIED + SET_COUNT))
  else
    refuse "settings" "gh api -X PATCH repos/$SLUG was refused — the token needs admin rights on it"
  fi
fi

echo ""
if [ "$REFUSED" -gt 0 ]; then
  echo "apply: $APPLIED change(s) applied, $REFUSED surface(s) refused — the report names them."
  exit 3
fi
echo "apply: $APPLIED change(s) applied."
exit 0
