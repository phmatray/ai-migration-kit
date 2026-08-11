#!/usr/bin/env bash
# Golden test for repo-profile.sh (rule 7: mandatory tool → mandatory test).
# Covers show's two paths (profile present / NO_PROFILE) and detect's contract:
# every field a probe cannot answer prints a TODO line instead of silent emptiness.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRIPT="skills/get-repo-profile/scripts/repo-profile.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. show without a profile → prints NO_PROFILE, exits 3.
tmp=$(mktemp -d)
rc=0; out=$(bash "$SCRIPT" show "$tmp") || rc=$?
[ "$rc" -eq 3 ] || fail "show without profile: expected exit 3, got $rc"
[ "$out" = "NO_PROFILE" ] || fail "show without profile: expected NO_PROFILE, got '$out'"

# 2. show with a profile → prints it back verbatim, exits 0.
mkdir -p "$tmp/.claude/skills"
printf '# Repo profile\n- fixture\n' > "$tmp/.claude/skills/repo-profile.md"
[ "$(bash "$SCRIPT" show "$tmp")" = "$(cat "$tmp/.claude/skills/repo-profile.md")" ] \
  || fail "show with profile: output differs from the committed file"

# 3. detect outside a git repository → exits 4.
tmp2=$(mktemp -d)
rc=0; bash "$SCRIPT" detect "$tmp2" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "detect outside git: expected exit 4, got $rc"

# 4. detect in a bare-bones git repo (no CLAUDE.md, no README, no remote, no workflows):
#    all sections present AND the TODO fallbacks actually fire — this is the regression
#    guard for the `pipeline || echo TODO` dead-fallback bug.
repo=$(mktemp -d)
git -C "$repo" init -q
git -C "$repo" -c user.email=t@test -c user.name=T commit -q --allow-empty -m "init"
out=$(bash "$SCRIPT" detect "$repo")
for s in "## Identity" "## Commit identity" "## Build system" "## CI gates" \
         "## Integration style" "## Labels" "## Issue templates" "## Architecture grain"; do
  grep -qF "$s" <<<"$out" || fail "detect: section '$s' missing"
done
grep -qF "TODO: no CLAUDE.md commit rule found" <<<"$out" \
  || fail "detect: commit-rule TODO fallback did not fire"
grep -qF "TODO: no obvious invariants" <<<"$out" \
  || fail "detect: architecture-grain TODO fallback did not fire"
grep -qF "TODO: no marker file at the repo root" <<<"$out" \
  || fail "detect: build-system TODO fallback did not fire"
# The one commit made above must be visible (probes emit real facts, not only TODOs).
grep -qF "T <t@test>" <<<"$out" || fail "detect: recent-authors probe lost the real fact"

# 5. The worktree-home probe reports the MEASURED ignore status, never a fixed claim (#71).
#    detect's whole contract is "facts a probe established", and this field was the exception: it
#    tested whether the directory EXISTS and the template then wrote "(git-ignored)" beside it. Those
#    are different questions, and the wrong one is the one that matters — an unignored worktree home
#    is exactly the repo where `git add -A` stages a worktree as a 160000 gitlink (#43).
#
#    Read only the "## Worktree home" section: asserting against the whole facts block would let an
#    unrelated section satisfy a grep. And the verdict phrases are matched WHOLE — "ignored" is a
#    substring of "NOT ignored", so a bare grep for it is true in both states and tests nothing.
wt_section() { awk '/^## Worktree home/{f=1;next} /^## /{f=0} f' <<<"$1"; }

wt=$(mktemp -d)
git -C "$wt" init -q
git -C "$wt" -c user.email=t@test -c user.name=T commit -q --allow-empty -m "init"
mkdir -p "$wt/.claude/worktrees"

# 5a. Present but NOT ignored — reported as such, and the existence fact is still emitted (the
#     profile needs to know WHICH home this repo uses; ignore status alone cannot say).
sec=$(wt_section "$(bash "$SCRIPT" detect "$wt")")
grep -qF 'is NOT ignored' <<<"$sec" \
  || fail "detect: an unignored worktree home was not reported as unignored:
$sec"
grep -qF 'present on disk: .claude/worktrees/' <<<"$sec" \
  || fail "detect: lost the fact of WHICH worktree home exists:
$sec"

# 5b. The control, and it must reach the exit-0 branch — which means ignoring BOTH homes. Ignoring
#     only .claude/worktrees/ leaves the guard refusing on .worktrees/, so the probe would still
#     print the NOT-ignored TODO and this case would assert nothing it claims to.
printf '.claude/worktrees/\n.worktrees/\n' > "$wt/.gitignore"
sec=$(wt_section "$(bash "$SCRIPT" detect "$wt")")
grep -qF 'is NOT ignored' <<<"$sec" \
  && fail "detect: reported a correctly ignored home as NOT ignored:
$sec"
grep -qF 'ignore status verified' <<<"$sec" \
  || fail "detect: the exit-0 branch never fired for a fully configured repo:
$sec"

# 5c. The over-broad rule (guard exit 2). Both homes ARE ignored, so there is no #43 hazard and the
#     probe must not report one — but it must flag that the repo can no longer commit its profile.
printf '.claude/\n.worktrees/\n' > "$wt/.gitignore"
sec=$(wt_section "$(bash "$SCRIPT" detect "$wt")")
grep -qF 'is NOT ignored' <<<"$sec" \
  && fail "detect: an over-broad rule was reported as an unignored home:
$sec"
grep -qF 'cannot carry a committed profile' <<<"$sec" \
  || fail "detect: exit 2 did not flag the profile cost:
$sec"

# 5d. A rule that is in EFFECT but not committed (.git/info/exclude) must not become a durable claim
#     about the repo. check-ignore is satisfied by machine-local rules, so exit 0 alone would record
#     "verified ignored" for a repo whose teammates and CI stage the worktree regardless.
wt2=$(mktemp -d)
git -C "$wt2" init -q
git -C "$wt2" -c user.email=t@test -c user.name=T commit -q --allow-empty -m "init"
printf '.claude/worktrees/\n.worktrees/\n' >> "$wt2/.git/info/exclude"
sec=$(wt_section "$(bash "$SCRIPT" detect "$wt2")")
grep -qF 'ignored on this machine only' <<<"$sec" \
  || fail "detect: a machine-local rule was recorded as a property of the repo:
$sec"

rm -rf "$tmp" "$tmp2" "$repo" "$wt" "$wt2"
echo "repo-profile golden test OK"
