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
#            case-insensitively), or the slug is empty, or it is gh's own `{owner}/{repo}`
#            placeholder — which the merge-pr prose passes verbatim, `gh api` expands from the
#            checkout itself, and KIT_REPO_SLUG therefore keeps untouched — AND
#            `gh auth token --hostname <host>` succeeds. That probe is a local credential lookup,
#            not `gh auth status`, which validates over the network; its stdout, the token itself,
#            goes to /dev/null. It runs with GH_ENTERPRISE_TOKEN and GITHUB_ENTERPRISE_TOKEN
#            withheld: with either exported, gh answers yes for ANY host but github.com, and an SSH
#            config alias such as `github-work` would pass for a GHE host. So a host counts only when
#            gh holds a stored credential for it (or GH_TOKEN covers it: github.com, ghe.com); a GHES
#            reached only through an enterprise token variable takes a HOST/OWNER/REPO slug or a
#            GH_HOST instead. A checkout of a DIFFERENT repository must not lend its host to this
#            one, and an origin host gh holds no credentials for is left alone, never guessed at.
#         4. nothing: gh's own default host, exactly as before this file existed.
#
#       Returns 0. A slug of one segment, of four or more, or with an empty segment (`acme/`,
#       `a//b`, `/a/b`) returns 2 before any gh call and writes "gh-host: malformed repository slug
#       '<slug>' — expected [HOST/]OWNER/REPO" on stderr; the caller then exits with its own
#       usage-error code.
#
# The origin parse copies hooks/autodev-stop-gate.sh's sed expressions (#471) — the hook fires on
# every Stop in every repository and fails open, and making it load a skill file is a separate
# decision. Both implementations correctly handle userinfo with colons in credentialed origins:
# `https://user:token@host/…` yields the host, not the user (#514, #532).
# Case-folding is `tr`, never ${var,,} (macOS bash 3.2).
# The slug lands in KIT_REPO_SLUG, never GH_REPO: GH_REPO is a real gh environment variable, and
# exporting it would silently retarget every gh call the caller makes.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "_gh-host.sh: this file is SOURCED, never executed — source it, then call gh_host_resolve <slug>" >&2
  exit 2
fi

gh_host_resolve() {
  local slug="${1-}" segments=1 rest="" host="" url="" origin_host="" origin_slug="" wanted=""
  KIT_REPO_SLUG=""
  if [ -n "$slug" ]; then
    # An empty segment is malformed: `acme/widgets/` would otherwise read as host `acme`. The rest
    # is counted in bash, not with awk: a caller can run under a PATH pinned to a handful of tools
    # (tests/repo-profile/test.sh rebuilds it from symlinks), and a missing tool must never change
    # the answer.
    case "$slug" in
      /*|*/|*//*) segments=0 ;;
      *) rest="$slug"
         while :; do
           case "$rest" in
             */*) rest="${rest#*/}"; segments=$((segments + 1)) ;;
             *) break ;;
           esac
         done ;;
    esac
    case "$segments" in
      2) KIT_REPO_SLUG="$slug" ;;
      3) host=$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]' 2>/dev/null)
         # DNS names are case-insensitive, so lowercasing is tidiness: a failed tr must not drop an
         # explicit host.
         [ -n "$host" ] || host="${slug%%/*}"
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
    | sed -E -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#^[^@/]*@##' -e 's#[:/].*$##' \
    | tr '[:upper:]' '[:lower:]')
  case "$origin_host" in ''|*/*) return 0 ;; esac
  if [ -n "$KIT_REPO_SLUG" ] && [ "$KIT_REPO_SLUG" != "{owner}/{repo}" ]; then
    origin_slug=$(printf '%s' "$url" \
      | sed -E -e 's#(\.git)?/*$##' -e 's#.*[:/]([^/:]+)/([^/:]+)$#\1/\2#' \
      | tr '[:upper:]' '[:lower:]')
    wanted=$(printf '%s' "$KIT_REPO_SLUG" | tr '[:upper:]' '[:lower:]')
    [ "$origin_slug" = "$wanted" ] || return 0
  fi
  # Enterprise token variables withheld: with one exported, gh vouches for any host at all. Unset
  # in a subshell rather than through `env`, so the probe needs no tool beyond gh itself.
  ( unset GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    gh auth token --hostname "$origin_host" ) > /dev/null 2>&1 || return 0
  GH_HOST="$origin_host"
  export GH_HOST
  return 0
}
