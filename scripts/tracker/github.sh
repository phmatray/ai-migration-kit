#!/usr/bin/env bash
# github.sh — the GitHub backend of the tracker contract (#505): a verb in, a normalised reply out.
#
# usage: github.sh <verb> [args…]        (invoked by scripts/tracker.sh, not by hand)
#
# GitHub is the REFERENCE backend. Every other host's backend is written against what this one
# prints, and this one is deliberately never reduced to a lowest common denominator: a verb prints
# what GitHub can actually say, and a host that cannot say it answers NOT_IMPLEMENTED rather than
# everyone answering less.
#
# The repository comes from TRACKER_REPO (`tracker.sh --repo <slug>`), empty for "this checkout".
# The host is resolved through skills/_shared/scripts/_gh-host.sh (#514) rather than left to gh's
# default: `gh -R OWNER/REPO` takes gh's DEFAULT host even inside a GitHub Enterprise checkout, and
# `gh api` never infers a host at all, so every kit script addressing a repository by a bare
# OWNER/REPO used to reach github.com. tests/gh-host/test.sh sweeps for exactly that omission.
#
# NORMALISATION, which is the whole point of a verb having a contract:
#   * `state` is lower-cased — gh answers "OPEN", the contract says "open", and a second backend
#     must not be free to pick either.
#   * `labels` are bare names, not gh's label objects.
#   * `issue-view` declares `"format":"markdown"` explicitly, so a host whose issue bodies are a
#     different dialect cannot quietly hand them back under the same verb.
#
# Exit codes (the dispatcher passes them through):
#   0  the verb answered
#   1  the host refused or failed — auth, network, a 404
#   2  bad invocation: no verb, a missing argument, a malformed slug
#   3  this backend does not implement the verb
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERB="${1-}"
[ -n "$VERB" ] || { echo "github: no verb given" >&2; exit 2; }
shift

# `verbs` is answered FIRST, before the helper is loaded or any host is resolved. The dispatcher
# calls it to decide whether this backend implements a verb at all, and that question must not need
# gh, a network or a credential — a backend that could only introspect itself when authenticated
# would report "not implemented" for every verb on a machine that is merely logged out.
if [ "$VERB" = verbs ]; then
  printf '%s\n' verbs auth repo issue-view \
    issue-search issue-comments issue-create issue-edit-body \
    issue-add-labels issue-remove-labels issue-reopen issue-comment label-list label-create
  exit 0
fi

. "$HERE/../../skills/_shared/scripts/_gh-host.sh" || {
  echo "github: REFUSED — cannot load skills/_shared/scripts/_gh-host.sh; reinstall the kit" >&2
  exit 2; }

# Sets KIT_REPO_SLUG (empty in, empty out) and exports GH_HOST when a host resolves. Returns 2 on a
# malformed slug, having called nothing.
gh_host_resolve "${TRACKER_REPO-}" || exit 2

case "$VERB" in
  auth)
    gh api user --jq .login || exit 1
    ;;

  repo)
    # `gh repo view` takes the slug POSITIONALLY — `--repo`/`-R` is an `issue`/`pr` flag and is
    # rejected here. Omitted entirely when there is no slug, so gh reads the checkout itself.
    out=$(gh repo view ${KIT_REPO_SLUG:+"$KIT_REPO_SLUG"} --json nameWithOwner,defaultBranchRef) \
      || exit 1
    printf '%s' "$out" | jq -c --arg host "${GH_HOST:-github.com}" \
      '{slug: .nameWithOwner, host: $host, defaultBranch: (.defaultBranchRef.name // null)}'
    ;;

  issue-view)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-view needs an issue number" >&2; exit 2; }
    out=$(gh issue view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} \
            --json number,title,state,body,labels,url) || exit 1
    printf '%s' "$out" | jq -c \
      '{number, title, state: (.state | ascii_downcase), body,
        labels: [(.labels // [])[].name], url, format: "markdown"}'
    ;;

  issue-search)
    # Every filter is optional — a bare `issue-search` with no --query is valid (Step 3's
    # open-refactor scan filters by --label alone). --label may repeat.
    Q=""; ST=""; LIM=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --query) Q="${2-}"; shift 2 ;;
        --state) ST="${2-}"; shift 2 ;;
        --label) LBLS+=("${2-}"); shift 2 ;;
        --limit) LIM="${2-}"; shift 2 ;;
        *) echo "github: issue-search: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    ARGS=(issue list --json number,title,state)
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    [ -n "$Q" ] && ARGS+=(--search "$Q")
    [ -n "$ST" ] && ARGS+=(--state "$ST")
    [ -n "$LIM" ] && ARGS+=(--limit "$LIM")
    if [ "${#LBLS[@]}" -gt 0 ]; then
      for l in "${LBLS[@]}"; do ARGS+=(--label "$l"); done
    fi
    out=$(gh "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -c '[.[] | {number, title, state: (.state | ascii_downcase)}]'
    ;;

  issue-comments)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-comments needs an issue number" >&2; exit 2; }
    out=$(gh issue view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --json comments) || exit 1
    printf '%s' "$out" | jq -c '[.comments[].body]'
    ;;

  issue-create)
    TITLE=""; BODY_FILE=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     TITLE="${2-}"; shift 2 ;;
        --label)     LBLS+=("${2-}"); shift 2 ;;
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$TITLE" ] || { echo "github: issue-create needs --title" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-create needs a non-empty --body-file" >&2; exit 2; }
    ARGS=(issue create --title "$TITLE" --body-file "$BODY_FILE")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    # A label not in the live set is passed through, exactly as `gh issue create --label` does
    # today — the host decides, and the caller (create-issue Step 7) is what checks the live set
    # first and flags the gap; this verb does not second-guess it.
    if [ "${#LBLS[@]}" -gt 0 ]; then
      for l in "${LBLS[@]}"; do ARGS+=(--label "$l"); done
    fi
    url=$(gh "${ARGS[@]}") || exit 1
    num=$(printf '%s' "$url" | grep -oE '[0-9]+$') || {
      echo "github: issue-create: could not read an issue number off of: $url" >&2; exit 1; }
    jq -nc --arg n "$num" --arg u "$url" '{number: ($n | tonumber), url: $u}'
    ;;

  issue-edit-body)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-edit-body: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-edit-body needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-edit-body refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    gh issue edit "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --body-file "$BODY_FILE" || exit 1
    ;;

  issue-add-labels)
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "github: issue-add-labels needs an issue number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "github: issue-add-labels needs at least one label" >&2; exit 2; }
    ARGS=(issue edit "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    for l in "$@"; do ARGS+=(--add-label "$l"); done
    gh "${ARGS[@]}" || exit 1
    ;;

  issue-remove-labels)
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "github: issue-remove-labels needs an issue number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "github: issue-remove-labels needs at least one label" >&2; exit 2; }
    ARGS=(issue edit "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    for l in "$@"; do ARGS+=(--remove-label "$l"); done
    gh "${ARGS[@]}" || exit 1
    ;;

  issue-reopen)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-reopen: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-reopen needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-reopen refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    # gh's own `issue reopen` has no --body-file (only -c/--comment string) — the file is read
    # here, at the backend boundary, rather than asking every caller to pass a multi-kilobyte
    # reopening comment as a command-line argument.
    gh issue reopen "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --comment "$(cat "$BODY_FILE")" || exit 1
    ;;

  issue-comment)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-comment: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-comment needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-comment refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    gh issue comment "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --body-file "$BODY_FILE" || exit 1
    ;;

  label-list)
    ARGS=(label list --json name --limit 100)
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    out=$(gh "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -r '.[].name'
    ;;

  # Not one of the nine filing verbs Task 1 (#506) named, but the SAME migration (Step 7's Sub-area
  # bullet grows the taxonomy with `gh label create` when no fitting label exists) — added here
  # rather than left as the one direct `gh label` call AC5 would otherwise still catch.
  label-create)
    NAME="${1-}"; shift || true
    COLOR=""; DESC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --color)       COLOR="${2-}"; shift 2 ;;
        --description) DESC="${2-}"; shift 2 ;;
        *) echo "github: label-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$NAME" ] || { echo "github: label-create needs a name" >&2; exit 2; }
    ARGS=(label create "$NAME")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    [ -n "$COLOR" ] && ARGS+=(--color "$COLOR")
    [ -n "$DESC" ] && ARGS+=(--description "$DESC")
    gh "${ARGS[@]}" || exit 1
    ;;

  *)
    echo "github: does not implement '$VERB'" >&2
    exit 3
    ;;
esac
