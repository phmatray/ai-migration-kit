#!/usr/bin/env bash
# _gh-host.sh — which host `gh` talks to, decided in one place. SOURCED by the kit's gh-calling
# scripts, never executed.
#
# Why this file exists (#514). `gh -R OWNER/REPO` takes gh's DEFAULT host, even inside a GitHub
# Enterprise checkout, and `gh api` never infers a host at all (`--hostname`, default github.com).
# So on a GHE repository every kit script that addressed the repository by a bare OWNER/REPO
# reached github.com instead. Measured in 7 sessions: 13 tick-plan.sh refusals and 6 GraphQL
# "Could not resolve to a Repository" failures, each worked around by typing `export GH_HOST=…` into
# the same command — Claude Code runs every Bash call in a fresh shell, so an export made earlier
# never reaches the script. Only a resolution inside the script itself survives that. GH_HOST is the
# one lever gh honours on every subcommand (`-R`, `api`, GraphQL alike), and every child the script
# spawns inherits it.
#
# The leading underscore says this is not a command. There is deliberately no `set -euo pipefail`
# here: the callers set it, as they do for skills/implement-issue/scripts/_assert-branch.sh. It lives
# under skills/ rather than the kit root's scripts/ because skills/_shared/preconditions.md documents
# a skills-only adoption path in which scripts/ can be absent.
#
# ---------------------------------------------------------------------------------- the contract
#
#   gh_host_resolve <slug>
#       <slug> is [HOST/]OWNER/REPO, or empty. Sets KIT_REPO_SLUG to OWNER/REPO (empty in, empty
#       out) and exports GH_HOST when a host resolves. The FIRST rule that yields a host wins:
#
#         1. a HOST prefix on the slug, lowercased. The slug is the per-call choice, so it beats
#            everything, a preset GH_HOST included.
#         2. a GH_HOST the caller already set: kept, and never unset.
#         3. origin's host, when origin names the same OWNER/REPO as the slug (compared
#            case-insensitively) or the slug is empty, AND `gh auth token --hostname <host>`
#            succeeds. That probe is a local credential lookup, not `gh auth status`, which
#            validates over the network; its stdout, the token itself, goes to /dev/null. A checkout
#            of a DIFFERENT repository must not lend its host to this one, and an origin host gh
#            holds no credentials for (an SSH config alias such as `github-work`) is left alone
#            rather than guessed at.
#         4. nothing: gh's own default host, exactly as before this file existed.
#
#       Returns 0. A slug of one segment, or of four or more, returns 2 before any gh call and
#       writes "gh-host: malformed repository slug '<slug>' — expected [HOST/]OWNER/REPO" on
#       stderr; the caller then exits with its own usage-error code.
#
# The origin parse copies hooks/autodev-stop-gate.sh's two sed expressions (#471) rather than
# sourcing that hook: the hook fires on every Stop in every repository and fails open, and making it
# load a skill file is a separate decision. Case-folding is `tr`, never ${var,,} (macOS bash 3.2).
# The slug lands in KIT_REPO_SLUG, never GH_REPO: GH_REPO is a real gh environment variable, and
# exporting it would silently retarget every gh call the caller makes.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "_gh-host.sh: this file is SOURCED, never executed — source it, then call gh_host_resolve <slug>" >&2
  exit 2
fi

gh_host_resolve() {
  local slug="${1-}" segments="" host="" url="" origin_host="" origin_slug="" wanted=""
  KIT_REPO_SLUG=""
  if [ -n "$slug" ]; then
    segments=$(printf '%s\n' "$slug" | awk -F/ '{print NF}')
    case "$segments" in
      2) KIT_REPO_SLUG="$slug" ;;
      3) host=$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]')
         KIT_REPO_SLUG="${slug#*/}" ;;
      *) echo "gh-host: malformed repository slug '$slug' — expected [HOST/]OWNER/REPO" >&2
         return 2 ;;
    esac
  fi

  # 1. the slug's own host prefix
  if [ -n "$host" ]; then
    GH_HOST="$host"
    export GH_HOST
    return 0
  fi

  # 2. a GH_HOST the caller already set
  if [ -n "${GH_HOST:-}" ]; then
    export GH_HOST
    return 0
  fi

  # 3. origin's host, for the same repository, when gh holds credentials for it
  url=$(git remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  origin_host=$(printf '%s' "$url" \
    | sed -E -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#^[^@/:]*@##' -e 's#[:/].*$##' \
    | tr '[:upper:]' '[:lower:]')
  case "$origin_host" in ''|*/*) return 0 ;; esac
  if [ -n "$KIT_REPO_SLUG" ]; then
    origin_slug=$(printf '%s' "$url" \
      | sed -E -e 's#(\.git)?/*$##' -e 's#.*[:/]([^/:]+)/([^/:]+)$#\1/\2#' \
      | tr '[:upper:]' '[:lower:]')
    wanted=$(printf '%s' "$KIT_REPO_SLUG" | tr '[:upper:]' '[:lower:]')
    [ "$origin_slug" = "$wanted" ] || return 0
  fi
  gh auth token --hostname "$origin_host" > /dev/null 2>&1 || return 0
  GH_HOST="$origin_host"
  export GH_HOST
  return 0
}
