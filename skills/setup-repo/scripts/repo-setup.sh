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
DESIRED="$(python3 "$PARSER" "$MANIFEST")" || exit 2

echo "manifest: $MANIFEST"
