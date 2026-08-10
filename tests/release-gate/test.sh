#!/usr/bin/env bash
# Golden test for scripts/release-gate.sh — a change to skills/** must ship a version bump.
#
# Why this gate exists: PR #5 fixed a data-loss bug in skills/implement-issue, merged green, and
# reached exactly zero consumers — the plugin cache is an install-time copy keyed by version, and
# plugin.json still said 1.9.0 (issue #6). A merged fix nobody loads is not a shipped fix, and
# nothing in CI noticed. This gate makes that failure impossible to merge silently.
set -euo pipefail
cd "$(dirname "$0")/../.."

GATE="./scripts/release-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# changed_files <name> <path>... -> writes a changed-file list, echoes its path
changed_files() {
  local name="$1"; shift
  local f="$WORK/$name.txt"
  : > "$f"
  for p in "$@"; do echo "$p" >> "$f"; done
  echo "$f"
}

# releasable <label> <base> <head> <list>  — expect exit 0
releasable() {
  local label="$1"; shift
  if ! "$GATE" "$@" > "$WORK/out" 2>&1; then
    echo "FAIL [$label]: expected releasable (exit 0), got refusal:"; cat "$WORK/out"; exit 1
  fi
  echo "  ok: $label — releasable"
}

# blocked <label> <base> <head> <list>  — expect non-zero
blocked() {
  local label="$1"; shift
  if "$GATE" "$@" > "$WORK/out" 2>&1; then
    echo "FAIL [$label]: expected the gate to BLOCK, got exit 0:"; cat "$WORK/out"; exit 1
  fi
  # The refusal must name the reason, or it is unactionable in a CI log.
  grep -qi 'version' "$WORK/out" || { echo "FAIL [$label]: refusal doesn't mention the version"; cat "$WORK/out"; exit 1; }
  echo "  ok: $label — blocked with a reason"
}

# ---------------------------------------------------------------- the core rule

# The exact PR #5 situation: a skills fix that would ship to nobody.
blocked "skills-changed-no-bump" 1.9.0 1.9.0 \
  "$(changed_files a skills/implement-issue/references/github-mechanics.md)"

releasable "skills-changed-with-bump" 1.9.0 1.9.1 \
  "$(changed_files b skills/implement-issue/references/github-mechanics.md)"

# ---------------------------------------------------------------- exemptions

releasable "docs-only-no-bump" 1.9.0 1.9.0 "$(changed_files c docs/backlog.md README.md)"
releasable "tests-only-no-bump" 1.9.0 1.9.0 "$(changed_files d tests/tick-plan/test.sh)"
releasable "samples-only-no-bump" 1.9.0 1.9.0 "$(changed_files e samples/LegacyShop/src/x.cs)"
releasable "ci-only-no-bump" 1.9.0 1.9.0 "$(changed_files f .github/workflows/ci.yml)"
releasable "nothing-changed" 1.9.0 1.9.0 "$(changed_files g)"

# A skills change mixed with exempt paths is still a skills change.
blocked "mixed-skills-and-docs-no-bump" 1.9.0 1.9.0 \
  "$(changed_files h docs/backlog.md skills/create-issue/SKILL.md README.md)"

# A path that merely CONTAINS "skills" elsewhere must not trip the gate.
releasable "not-really-skills" 1.9.0 1.9.0 "$(changed_files i docs/writing-skills.md tests/skills/check-frontmatter.py)"

# ---------------------------------------------------------------- version direction

# Any change of version satisfies the gate; the gate's job is "was this released?", not semver policy.
releasable "minor-bump" 1.9.0 1.10.0 "$(changed_files j skills/merge-pr/SKILL.md)"

# ---------------------------------------------------------------- misuse fails closed

if "$GATE" > "$WORK/out" 2>&1; then
  echo "FAIL [no-args]: the gate accepted missing arguments"; exit 1
fi
echo "  ok: no-args — refused"

if "$GATE" 1.9.0 1.9.1 "$WORK/definitely-not-here.txt" > "$WORK/out" 2>&1; then
  echo "FAIL [missing-list]: the gate accepted an unreadable changed-file list"; exit 1
fi
echo "  ok: missing-list — refused (an unreadable list must never read as 'nothing changed')"

echo "release-gate golden test OK"
