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
wt=$(mktemp -d)
git -C "$wt" init -q
git -C "$wt" -c user.email=t@test -c user.name=T commit -q --allow-empty -m "init"
mkdir -p "$wt/.claude/worktrees"

# 5a. Present but NOT ignored — must be reported as such, and must not claim git-ignored.
out=$(bash "$SCRIPT" detect "$wt")
grep -qE '\.claude/worktrees/.*NOT ignored' <<<"$out" \
  || fail "detect: an unignored worktree home was not reported as unignored:
$(grep -A2 'Worktree home' <<<"$out")"
grep -qE '\.claude/worktrees/ +\(git-ignored\)' <<<"$out" \
  && fail "detect: claimed (git-ignored) for a home that is not ignored"

# 5b. The same repo once the rule exists — the control. Without it, 5a could pass merely because the
#     probe stopped mentioning the path at all.
printf '.claude/worktrees/\n' > "$wt/.gitignore"
out=$(bash "$SCRIPT" detect "$wt")
grep -qE '\.claude/worktrees/.*ignored' <<<"$out" \
  || fail "detect: a correctly ignored worktree home vanished from the report"
grep -qE '\.claude/worktrees/.*NOT ignored' <<<"$out" \
  && fail "detect: reported an ignored home as NOT ignored"

rm -rf "$tmp" "$tmp2" "$repo" "$wt"
echo "repo-profile golden test OK"
