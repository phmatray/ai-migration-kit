#!/usr/bin/env bash
# Golden test for release-title-gate.sh — the check that a PR touching skills/** carries a PR
# title release-please will actually release.
#
# Written fail-path-first, on purpose: #16 removed a `metadata.version` field that "looked
# authoritative precisely because a test appeared to guard it". A gate that cannot be shown to
# fail is that same bug wearing a CI badge — so every refusal below asserts both the non-zero
# exit AND that the message says which type it refused and why.
set -euo pipefail
cd "$(dirname "$0")/../.."

GATE="./scripts/release-title-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# Asserts: the gate refused (exit 1) AND explained itself, naming the given substring.
refuses() {
  local name="$1" want="$2"; shift 2
  local out rc=0
  out=$("$GATE" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL [$name]: expected a refusal, got exit 0"; echo "$out"; exit 1
  fi
  if [ "$rc" -ne 1 ]; then
    echo "FAIL [$name]: expected exit 1 (refusal), got exit $rc"; echo "$out"; exit 1
  fi
  if ! printf '%s' "$out" | grep -qF -- "$want"; then
    echo "FAIL [$name]: refusal did not mention '$want':"; echo "$out"; exit 1
  fi
  echo "  ok: $name — refused, message names '$want'"
}

# Asserts: the gate passed (exit 0).
passes() {
  local name="$1"; shift
  local out rc=0
  out=$("$GATE" "$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$name]: expected exit 0, got exit $rc"; echo "$out"; exit 1
  fi
  echo "  ok: $name — passed"
}

# ---------------------------------------------------------------- refusals

# 1. The measured production case. PR #20's own branch commit was exactly this title, changing
#    six skills/*/SKILL.md. It shipped only because the PR *title* was retyped `fix(skills):`
#    by hand — two unenforced conventions were the whole guarantee (see #27).
refuses chore-skills 'chore' \
  "chore(skills): drop the per-skill version" skills/merge-pr/SKILL.md

# 2. A PR touching skills/** AND other paths still gates on skills/**.
refuses mixed-changeset 'chore' \
  "chore(skills): tidy the guides" skills/create-issue/SKILL.md README.md

# 3. Renames and deletions under skills/** count as touching it — CI passes both sides of a
#    rename (--no-renames), and a deleted path is still a path.
refuses deleted-skill-file 'chore' \
  "chore(skills): retire the old reference" skills/legacy-upgrade/references/phase-9.md

# 4. The exact mistake implement-issue warns about: an issue-derived title whose subject reads
#    like a scope. 'CSV export' is not a type, so this is not a Conventional Commits header.
refuses subject-in-type-position 'Conventional Commits' \
  "CSV export: header row missing" skills/merge-pr/SKILL.md

# 5. No prefix at all — fail closed, do not guess an intent.
refuses no-prefix 'Conventional Commits' \
  "update stuff" skills/merge-pr/SKILL.md

# 6. release-please matches types case-sensitively, so `Fix` is not `fix` and releases nothing.
#    Must say *that*, rather than reading as "not conventional".
refuses uppercase-type 'lowercase' \
  "Fix(skills): stop dropping the follow-up list" skills/merge-pr/SKILL.md

# 7. Other hidden types are refused the same way, naming themselves. Asserted on the quoted type
#    so a two-letter type like `ci` cannot pass by matching some unrelated substring.
refuses docs-skills "'docs'" "docs(skills): clarify the trigger list" skills/followups/SKILL.md
refuses ci-skills   "'ci'"   "ci(skills): reorder the steps"          skills/followups/SKILL.md

# ---------------------------------------------------------------- passes

# 8. The releasable types.
passes fix-skills  "fix(skills): stop dropping the follow-up list" skills/merge-pr/SKILL.md
passes feat-skills "feat(skills): add a follow-up harvester"       skills/merge-pr/SKILL.md

# 9. A breaking marker releases whatever the type is (major bump), so it passes.
passes breaking-feat     "feat(skills)!: drop the legacy plan comment path" skills/create-issue/SKILL.md
passes breaking-non-feat "refactor(skills)!: rename the profile contract"   skills/get-repo-profile/SKILL.md

# 10. Not applicable: a chore PR that touches no skills path is fine — validating those was an
#     explicit non-goal (#27), a chore(deps) bump releasing nothing is correct behaviour.
passes chore-no-skills "chore(deps): update actions/checkout action to v7" .github/workflows/ci.yml README.md

# 11. The skills/** match is anchored at the repo root: docs/skills/ and .claude/skills/ are not
#     the shipped skills, so they must not trip the gate.
passes nested-skills-dir "docs: rewrite the walkthrough" docs/skills/guide.md .claude/skills/repo-profile.md

# 12. A releasable title is fine even with no skills path — the gate never *requires* a type.
passes fix-no-skills "fix(ci): pin the runner image" .github/workflows/ci.yml

# ---------------------------------------------------------------- plumbing must fail closed

# 13. No paths at all is a broken caller, not an empty diff. Answering "not applicable" there
#     would reopen the hole from the other end, so it is exit 2, distinct from a refusal.
rc=0; out=$("$GATE" "chore(skills): x" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-paths]: expected exit 2, got $rc"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF 'plumbing failure' \
  || { echo "FAIL [no-paths]: message does not name the plumbing failure:"; echo "$out"; exit 1; }
echo "  ok: no-paths — exit 2, named as a plumbing failure"

# 14. No arguments at all — usage, exit 2.
rc=0; "$GATE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-args]: expected exit 2, got $rc"; exit 1; }
echo "  ok: no-args — exit 2"

# 15. Runs from a foreign working directory (plugin-install simulation, cf. ci.yml). The gate
#     reads no files, so this must hold for both the pass and the refuse path.
KIT="$PWD"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && bash "$KIT/$GATE" "fix(skills): x" skills/merge-pr/SKILL.md >/dev/null 2>&1 ) \
  || { echo "FAIL [foreign-cwd]: a valid title was refused from another directory"; exit 1; }
if ( cd "$WORK" && bash "$KIT/$GATE" "chore(skills): x" skills/merge-pr/SKILL.md >/dev/null 2>&1 ); then
  echo "FAIL [foreign-cwd]: a chore title passed from another directory"; exit 1
fi
echo "  ok: foreign cwd — same verdict either way"

echo "release-title-gate golden test OK"
