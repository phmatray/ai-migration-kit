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

rm -rf "$tmp" "$tmp2" "$repo"
echo "repo-profile golden test OK"
