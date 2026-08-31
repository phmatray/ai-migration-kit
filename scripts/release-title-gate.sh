#!/usr/bin/env bash
# release-title-gate.sh — a PR that changes SHIPPED PLUGIN CONTENT must carry a PR title
# release-please will actually release.
#
# "Shipped" is defined by exclusion, in the NON_SHIPPED list below: everything in this repo is
# plugin content except the development-only paths named there. The gate originally asked the
# narrower question "does this touch skills/**" (#27), but a consumer installs a whole-repo checkout
# of the tagged commit and plugin.json declares no file allowlist, so scripts/, commands/,
# templates/, hooks/ and requirements.json reach them just as directly. #55 widened the predicate to
# match the invariant the header had claimed all along.
#
# Why this exists (#27). Consumers load an install-time cache keyed by plugin version, not a live
# view of this repo (#6), so a fix that ships without a release reaches nobody while CI is
# green and `main` looks correct. #7 enforced that with a per-PR version bump; #14 retired it when
# release-please was installed, correctly — release-please inverts the rule, feature PRs never
# bump, the release PR does. The replacement guarantee is "every merged fix lands in the next
# release PR", and it holds only if the commit landing on `main` carries a type release-please
# releases. Nothing checked that.
#
# It checks the TITLE, not the branch commits, because this repo squash-merges: the PR title is
# what becomes the commit on `main`. Asserting the branch commits would fail PRs that land
# perfectly well — that is what made #7's gate untenable, and it would have failed PR #20, which
# was correct. That coupling is recorded in release-please-config.json.
#
# Usage:
#   release-title-gate.sh <pr-title> <changed-file…>
#
# Exit codes:
#   0  pass — either every changed path is non-shipped, or the title is releasable
#   1  refuse — the title would land a change to shipped content that cuts no release
#   2  usage / plumbing error — the caller did not supply what the gate needs to decide
#
# Takes everything as arguments and reads no files, so it runs from any working directory and
# needs no secrets (fork PRs must be able to run it).

set -euo pipefail

# --------------------------------------------------------------------- the releasable set
# SINGLE SOURCE, and measured rather than assumed. release-please decides whether to cut a
# release at all by filtering commits through DEFAULT_CHANGELOG_SECTIONS
# (release-please, src/util/filter-commits.ts) and skipping the release when nothing user-facing
# survives. Visible in that table — hence releasable:
#     feat, fix, perf, revert
# Hidden there — hence NOT releasable:
#     chore, docs, style, refactor, test, build, ci
# `feature` appears in neither list, so it is filtered out too and cuts no release.
# A breaking change is releasable whatever its type: filter-commits.ts keeps a hidden-section
# commit that carries a BREAKING CHANGE note, which is what the `!` marker produces — that is
# the rule applied further down, and it comes from the same table, not from intuition.
# This repo runs release-type `simple` with no changelog-sections override
# (release-please-config.json), so those defaults are the ones in force. Override them there and
# this list has to move with them.
RELEASABLE_TYPES="feat fix perf revert"

# --------------------------------------------------------------------- the non-shipped set
# SINGLE SOURCE, and deliberately a DENY-list (#55). The gate used to ask "does this touch
# skills/**", but skills/ was only ever a proxy for the real invariant: "does this change what a
# consumer's installed plugin does". An installed plugin is a whole-repo checkout of the tagged
# commit at ~/.claude/plugins/cache/<marketplace>/ai-migration-kit/<version>/, and plugin.json
# declares no file allowlist — so scripts/, commands/, templates/, requirements.json and hooks/ are
# every bit as install-time as skills/. Under the old allowlist a `chore:` fix to any of them cut no
# release, reached no consumer, and the gate said "not applicable" (that is #6's failure mode with
# the gate watching the wrong door; #35 and #34 were both such fixes).
#
# So the list below is what is NOT shipped, and everything else is gated. It FAILS CLOSED: a new
# top-level directory is gated until someone argues it onto this list, rather than ungated until
# someone notices. Each entry has to earn its place, which is the right way round — this list is the
# thing that gets reviewed.
#
# Entries ending in `/` are directory prefixes anchored at the repo root; the rest are exact paths.
# Anchoring matters in both directions: docs/skills/… must not read as skills/…, and `.claude/` must
# not swallow `.claude-plugin/`.
#
#   docs/      documentation ABOUT the kit — but see SHIPPED_ANYWAY: docs/backlog.md is not
#   tests/     the kit's own golden tests — but see SHIPPED_ANYWAY: the xunit transform is not
#   evals/     the skill-evaluation harness — development-only
#   reviews/   archived code-review notes — development-only
#   samples/   the frozen LegacyShop fixture — a test input, not shipped behaviour
#   .github/   this repo's own CI and issue config — not part of the plugin
#   .claude/   this repo's own agent config. Nothing under it is tracked today, so the entry is
#              PRE-EMPTIVE: it keeps a committed repo-profile from gating repo-hygiene PRs, and it
#              is what makes the `.claude/` vs `.claude-plugin/` anchoring caveat above worth
#              stating. Delete it if that never happens.
#   CHANGELOG.md     regenerated by release-please; it is an OUTPUT of releasing, not an input
#   README.md        judgement call: it does ship in the cache, but it changes no behaviour a
#   ARCHITECTURE.md  cached skill runs. Recorded here so the next reader can overturn it knowingly.
#
# The last group is this repo's own development config. It is not in the plugin's behaviour at all,
# and gating it would force repo-hygiene PRs (#43 gitignored a directory) to cut a release whose
# changelog entry would be false to consumers. renovate.json earns its place twice over: Renovate's
# own onboarding and config-migration PRs are titled `Configure Renovate`, which is not a
# Conventional Commits header at all, so gating it would refuse a PR no bot can retitle.
#   .gitignore .editorconfig LICENSE renovate.json release-please-config.json
NON_SHIPPED=(
  docs/ tests/ evals/ reviews/ samples/ .github/ .claude/
  CHANGELOG.md README.md ARCHITECTURE.md
  .gitignore .editorconfig LICENSE renovate.json release-please-config.json
)

# --------------------------------------------------------------------- the exceptions
# Paths whose DIRECTORY is excluded above but which a shipped skill resolves out of the install
# cache by name. A top-level directory is the wrong granularity for these two, and taking the
# directory's word for it would reopen #55 inside the very list that closed it:
#
#   tests/xunit-v3/apply-transform.py
#       skills/migrate-legacy/references/xunit-v3-migration.md calls it "<kit>/tests/xunit-v3/
#       apply-transform.py … the witness", and its XUNIT_V3_VERSION / COVERAGE_EXT_VERSION
#       constants are baked into EVERY migrated csproj. renovate.json has a customManager watching
#       this exact file (#36) precisely because those versions ship.
#   docs/backlog.md
#       skills/review-followups/SKILL.md rule 7 mandates `--backlog "<kit>/docs/backlog.md"`, and defines
#       <kit> as the plugin root — the install cache, not this checkout.
#
# Checked BEFORE the deny-list, so they stay gated.
#
# The mirror case exists too (#58): a shipped directory can hold development-only content of its
# own, e.g. a per-skill evals/ fixture — trigger-eval cases for that skill's own SKILL.md, never
# read by a consumer's installed plugin. SHIPPED_ANYWAY above is "excluded directory, shipped
# file"; the nested-evals rule in is_shipped() below is "shipped directory, non-shipped file" —
# same asymmetry, opposite direction. It is a RULE (any path segment literally named `evals`
# anywhere under skills/**), not a second literal list here, because a list would have to be kept
# in step with every skill that ever adds one.
SHIPPED_ANYWAY=(
  tests/xunit-v3/apply-transform.py
  docs/backlog.md
)

# --------------------------------------------------------------------- release-please's own PR
# release-please opens a PR titled `chore(main): release X.Y.Z` that touches only these files.
# `chore` is not releasable — correctly, since that PR *is* the release — so gating it would refuse
# every release PR and deadlock the mechanism this gate exists to protect.
#
# The exemption is deliberately TITLE-shaped rather than a blanket path exclusion, because the
# condition really is about who opened the PR, not about which files are shipped. plugin.json is
# shipped: it carries name, description, keywords and is where mcpServers/hooks are declared (cf.
# 47f6c1e). Excluding the path outright would let `chore: reword the plugin description` escape.
# So both halves must hold — release-please's exact title AND a changeset that is a subset of what
# it writes.
RELEASE_PR_TITLE_PREFIX="chore(main): release "
RELEASE_PR_FILES=(
  .claude-plugin/plugin.json
  .release-please-manifest.json
  CHANGELOG.md
)

# Both lists on one line, for the refusal message. The exceptions have to be shown too: without
# them the message reads "…is shipped except: … tests/ …" to someone whose tests/ path was just
# refused, which looks like a bug in the gate rather than a deliberate carve-out.
NON_SHIPPED_ONELINE="${NON_SHIPPED[*]}"
SHIPPED_ANYWAY_ONELINE="${SHIPPED_ANYWAY[*]}"

# True (0) when the path is shipped plugin content. Unknown paths are shipped — the fail-closed
# direction. Arrays, not a word-split string: an entry containing a glob character would otherwise
# be pathname-expanded against whatever directory CI happens to run in.
is_shipped() {
  local path="$1" entry
  for entry in "${SHIPPED_ANYWAY[@]}"; do
    if [ "$path" = "$entry" ]; then return 0; fi
  done
  # The mirror case to SHIPPED_ANYWAY above (#58): a shipped directory can hold a development-only
  # `evals/` fixture at any depth beneath it. Matched as a path SEGMENT — anchored on `skills/` so
  # docs/skills/… and .claude/skills/… stay untouched, and on the `/evals/` boundary so a sibling
  # merely named evals-runner (a different segment) is not swept in — never as a bare substring,
  # which `*evals*` would have been.
  case "$path" in
    skills/evals/*|skills/*/evals/*) return 1 ;;
  esac
  for entry in "${NON_SHIPPED[@]}"; do
    case "$entry" in
      */) if [ "${path#"$entry"}" != "$path" ]; then return 1; fi ;;
      *)  if [ "$path" = "$entry" ]; then return 1; fi ;;
    esac
  done
  return 0
}

# True (0) only for release-please's own release PR: its title AND a changeset that is a subset of
# the files it writes. Either half alone is not enough.
is_release_pr() {
  local title="$1"; shift
  local path entry matched
  case "$title" in
    "$RELEASE_PR_TITLE_PREFIX"*) ;;
    *) return 1 ;;
  esac
  for path in "$@"; do
    matched=1
    for entry in "${RELEASE_PR_FILES[@]}"; do
      if [ "$path" = "$entry" ]; then matched=0; break; fi
    done
    if [ "$matched" -ne 0 ]; then return 1; fi
  done
  return 0
}

die() { printf 'release-title-gate: REFUSED — %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: release-title-gate.sh <pr-title> <changed-file…>

  <pr-title>       the pull request title, verbatim (github.event.pull_request.title)
  <changed-file…>  every path the PR touches, one per argument
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }

# Only when it is the sole argument. $1 is the PR title in the CI call, so an unguarded
# `-h|--help` case meant a pull request *titled* `--help` printed usage and exited 0 — a
# fail-open in a script whose whole contract is to fail closed.
if [ $# -eq 1 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
fi

TITLE="$1"; shift

# Zero paths is a broken caller, not an empty diff — refuse rather than silently conclude that no
# shipped content is touched. A diff step that produces nothing is the class of hole this gate
# exists to close, so it must not read as "not applicable".
[ $# -ge 1 ] || {
  printf 'release-title-gate: no changed paths supplied — cannot tell whether shipped content is touched.\n' >&2
  printf '  The caller (CI) must pass the merge-base diff; an empty list is a plumbing failure.\n' >&2
  exit 2
}

# --------------------------------------------------------------------- 0. release-please's own PR
# Checked before anything else: this is the one PR whose non-releasable type is correct.
if is_release_pr "$TITLE" "$@"; then
  echo "release-title-gate: release-please's own release PR — exempt. OK."
  exit 0
fi

# --------------------------------------------------------------------- 1. is the gate relevant?
# One shipped path is enough: a changeset that touches scripts/ and docs/ still has to release.
touches_shipped=0
for path in "$@"; do
  if is_shipped "$path"; then touches_shipped=1; break; fi
done

if [ "$touches_shipped" -eq 0 ]; then
  echo "release-title-gate: no shipped plugin content in this change — not applicable."
  exit 0
fi

# --------------------------------------------------------------------- 2. parse the title
# Conventional Commits header: <type>[(scope)][!]: <description>
if [[ ! "$TITLE" =~ ^([A-Za-z]+)(\([^()]+\))?(!)?:\ +(.+)$ ]]; then
  die "this PR changes shipped plugin content, and its title is not a Conventional Commits header.

  title:    $TITLE
  required: <type>[(scope)][!]: <description>   e.g. fix(merge-pr): stop dropping the follow-up list

  A subject is not a type. An issue-derived title such as 'CSV export: header row missing' reads
  conventional at a glance, but 'CSV export' is a subject, not one of feat|fix|chore|docs|…: the
  type comes first, as a single lowercase word, then an optional (scope), then ': '."
fi

type="${BASH_REMATCH[1]}"
breaking="${BASH_REMATCH[3]}"

# release-please matches types case-sensitively, so `Fix(skills):` is not `fix` and releases
# nothing. Refuse with the reason rather than letting it read as "not conventional".
if [ "$type" != "$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')" ]; then
  die "the type '$type' is not lowercase.

  release-please matches Conventional Commits types case-sensitively, so '$type' cuts no release.
  Retitle with '$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')'."
fi

# --------------------------------------------------------------------- 3. would it release?
if [ -n "$breaking" ]; then
  echo "release-title-gate: '$type!' carries the breaking-change marker — major release. OK."
  exit 0
fi

case " $RELEASABLE_TYPES " in
  *" $type "*)
    echo "release-title-gate: '$type' is releasable. OK."
    exit 0
    ;;
esac

die "this PR changes shipped plugin content, but the type '$type' is not in the releasable set.

  title: $TITLE

  Consumers install a version-keyed cache of this plugin (#6) — a whole-repo checkout of the
  tagged commit — so a change to anything they run only reaches them once release-please cuts a
  release. That is not just skills/: scripts/, commands/, templates/, hooks/ and requirements.json
  are equally install-time (#55). Everything in this repo is shipped except:
    $NON_SHIPPED_ONELINE
  …minus these, which are excluded by directory but which a shipped skill resolves by name out of
  the install cache, so they stay gated:
    $SHIPPED_ANYWAY_ONELINE

  This repo squash-merges, so the PR title above is the commit release-please will read on main.
  A '$type:' commit cuts none: the change would sit on main, released later by some unrelated
  feat/fix, silently backdated into its notes.

  Retitle with one of: $RELEASABLE_TYPES — or add '!' if it really is a breaking change."
