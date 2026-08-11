#!/usr/bin/env bash
# Golden test for worktrees-ignored.sh — the guard that an agent worktree can never be committed.
#
# Written fail-path-first, like tests/release-title-gate/test.sh and for the same reason this
# repo keeps re-learning: a guard whose PASS path is the only one ever exercised proves nothing,
# and one that quietly stopped matching would stay green forever. Every case below drives the
# guard over a scratch repository whose .gitignore is written for that case.
#
# The three hazards the guard's own header names are all regressions a reader could plausibly
# introduce while "tidying", so each gets a case that goes red:
#   * swapping -q for -v          → the negation case
#   * dropping the trailing slash → the fresh-checkout case
#   * broadening to `.claude/`    → the repo-profile case
set -euo pipefail
cd "$(dirname "$0")/../.."

GUARD="./scripts/worktrees-ignored.sh"
[ -x "$GUARD" ] || { echo "FAIL: $GUARD missing or not executable"; exit 1; }
KIT="$PWD"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
n=0

# A fresh repo whose .gitignore is exactly $1. Nothing is created on disk beyond .gitignore —
# that absence is the fresh-checkout condition the trailing-slash rule exists for.
scratch() {
  n=$((n + 1))
  local dir="$WORK/r$n"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '%b' "$1" > "$dir/.gitignore"
  printf '%s' "$dir"
}

# Asserts the guard exited $2 and said something naming $3.
verdict() {
  local name="$1" want_rc="$2" want_msg="$3" dir="$4"
  local out rc=0
  out=$(bash "$KIT/$GUARD" -C "$dir" 2>&1) || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL [$name]: expected exit $want_rc, got $rc"; echo "$out"; exit 1
  fi
  if ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
    echo "FAIL [$name]: output did not mention '$want_msg':"; echo "$out"; exit 1
  fi
  echo "  ok: $name"
}

# ---------------------------------------------------------------- refusals

# 1. Nothing ignored — the state of this repo before #43.
verdict no-rule 1 'is NOT ignored' "$(scratch '')"

# 2. THE fresh-checkout case. The rule is correct and the directory does not exist, which is every
#    CI run. A guard querying `.claude/worktrees` without the trailing slash answers "not ignored"
#    here and fails a repo that is configured properly; with the slash it passes. This case is the
#    only thing keeping that slash in place.
verdict fresh-checkout 0 'is ignored' "$(scratch '.claude/worktrees/\n.worktrees/\n')"

# 3. THE negation case — why the guard must use -q and not -v. `check-ignore -v` exits 0 here
#    because a pattern matched, and the matching pattern is the negation: the path is NOT ignored.
#    A -v-based guard passes this; -q refuses it.
verdict negated 1 'is NOT ignored' \
  "$(scratch '.claude/worktrees/\n.worktrees/\n!.claude/worktrees/\n')"

# 4. A commented-out rule — why the guard must not grep .gitignore. The string is still in the
#    file, so a grep passes while `git add -A` stages the worktree.
verdict commented-out 1 'is NOT ignored' "$(scratch '#.claude/worktrees/\n.worktrees/\n')"

# 5. The second worktree home on its own. superpowers:using-git-worktrees Step 1b defaults to
#    `.worktrees/` when the harness offers no native tool, so covering only `.claude/` leaves a
#    reachable path open — measured: `git add -A` stages `.worktrees/<branch>` just the same.
verdict only-claude-home 1 '.worktrees/ is NOT ignored' "$(scratch '.claude/worktrees/\n')"
verdict only-plain-home  1 '.claude/worktrees/ is NOT ignored' "$(scratch '.worktrees/\n')"

# 6. THE broadening case, and the one nothing else in CI can see. `.claude/` ignores the worktrees
#    perfectly well — so a guard that only asked "are worktrees ignored?" stays green — while also
#    hiding `.claude/skills/repo-profile.md`, which get-repo-profile tells consumer repos to
#    commit. Distinct exit code, because it is a different mistake with a different fix.
verdict broadened 2 'was broadened' "$(scratch '.claude/\n.worktrees/\n')"

# 7. Broadened by a wildcard rather than by the directory — same damage, and `.claude/*` is what a
#    "tidy-up" is at least as likely to produce.
verdict broadened-glob 2 'was broadened' "$(scratch '.claude/*\n.worktrees/\n')"

# ---------------------------------------------------------------- passes

# 8. The shipped configuration: both homes ignored, the profile still visible.
verdict correct 0 'is still visible' "$(scratch '.claude/worktrees/\n.worktrees/\n')"

# 9. A consumer repo that ALSO ignores unrelated .claude/ children must still pass — the guard
#    forbids hiding the profile, not every rule under .claude/.
verdict narrow-siblings 0 'is still visible' \
  "$(scratch '.claude/worktrees/\n.worktrees/\n.claude/settings.local.json\n')"

# 10. The guard is read-only. It is handed a repo it does not own, so it must not create the
#     scratch directories it asks about — the reason the trailing-slash query replaced a `mkdir`.
dir=$(scratch '.claude/worktrees/\n.worktrees/\n')
bash "$KIT/$GUARD" -C "$dir" >/dev/null 2>&1
[ ! -e "$dir/.claude" ] || { echo "FAIL [read-only]: the guard created $dir/.claude"; exit 1; }
[ ! -e "$dir/.worktrees" ] || { echo "FAIL [read-only]: the guard created $dir/.worktrees"; exit 1; }
echo "  ok: read-only — audits the workspace without writing to it"

# 11. The real article, end to end: a genuine `git worktree add` into an unignored home, then a
#     `git add -A` in the MAIN checkout — note the location, because it is the only place the
#     gitlink is reachable from: run from inside the linked worktree the home lives in the parent
#     checkout and `add -A` sees nothing (measured, #68). Asserts BOTH that the guard refuses and what the damage
#     actually looks like — a single 160000 gitlink, not a copy of the tree. The guard's header
#     states that as measured fact; this is the measurement, so it cannot rot into folklore.
real="$WORK/real"
mkdir -p "$real"
git -C "$real" init -q -b main
git -C "$real" config user.email t@example.com
git -C "$real" config user.name "Golden Test"
printf 'x\n' > "$real/tracked.txt"
git -C "$real" add -A
git -C "$real" commit -qm base
git -C "$real" worktree add -q .claude/worktrees/feat -b feat

rc=0; bash "$KIT/$GUARD" -C "$real" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [real-worktree]: expected exit 1 on a live unignored worktree, got $rc"; exit 1; }

git -C "$real" add -A 2>/dev/null
entry=$(git -C "$real" ls-files -s -- .claude/worktrees/feat)
printf '%s' "$entry" | grep -q '^160000 ' \
  || { echo "FAIL [real-worktree]: expected a 160000 gitlink, got: $entry"; exit 1; }
[ "$(git -C "$real" ls-files -- .claude/worktrees | wc -l | tr -d ' ')" -eq 1 ] \
  || { echo "FAIL [real-worktree]: expected exactly one index entry for the worktree"; exit 1; }
echo "  ok: real-worktree — refused, and git add -A stages it as one 160000 gitlink"

# 12. Same repo, rule added: the guard passes and `git add -A` no longer sees the worktree. The
#     positive control for case 11 — without it, "nothing was staged" could just mean the tree
#     was empty.
git -C "$real" rm -r -q --cached .claude
printf '.claude/worktrees/\n.worktrees/\n' > "$real/.gitignore"
bash "$KIT/$GUARD" -C "$real" >/dev/null 2>&1 \
  || { echo "FAIL [real-worktree-fixed]: the guard still refuses a correctly configured repo"; exit 1; }
git -C "$real" add -A
[ -z "$(git -C "$real" ls-files -- .claude/worktrees)" ] \
  || { echo "FAIL [real-worktree-fixed]: git add -A still staged the worktree"; exit 1; }
echo "  ok: real-worktree-fixed — rule added, git add -A no longer stages it"

# ---------------------------------------------------------------- plumbing must fail closed

# 13. A path that is not a repository is a plumbing failure, never "nothing to check".
rc=0; bash "$KIT/$GUARD" -C "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [not-a-repo]: expected exit 3, got $rc"; exit 1; }
echo "  ok: not-a-repo — exit 3, distinct from any verdict"

# 14. -C without a value must not silently audit the current directory.
rc=0; bash "$KIT/$GUARD" -C >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [dangling-C]: expected exit 3, got $rc"; exit 1; }
echo "  ok: dangling-C — exit 3"

# 15. An unrecognised argument is refused rather than ignored.
rc=0; bash "$KIT/$GUARD" --repo /tmp >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [bad-arg]: expected exit 3, got $rc"; exit 1; }
echo "  ok: bad-arg — exit 3"

# 16. --help documents the exit codes, matching the guards in skills/implement-issue/scripts and
#     the plugin-install simulation in ci.yml that greps for exactly this.
bash "$KIT/$GUARD" --help 2>&1 | grep -q 'Exit codes:' \
  || { echo "FAIL [help]: --help does not document the exit codes"; exit 1; }
echo "  ok: help — documents the exit codes"

# 17. Runs from a foreign working directory (plugin-install simulation, cf. ci.yml): the verdict
#     must follow -C, never the ambient CWD.
dir=$(scratch '')
( cd "$WORK" && bash "$KIT/$GUARD" -C "$dir" >/dev/null 2>&1 ) \
  && { echo "FAIL [foreign-cwd]: an unignored repo passed from another directory"; exit 1; }
echo "  ok: foreign cwd — the verdict follows -C, not the ambient directory"

# 18. THE shape the skills invoke (#71): a consumer installs the kit as a plugin, so the guard runs
#     from a directory that is not this repository — and, in the plugin cache, need not be a git
#     repository at all. Case 17 varies the working directory; this varies the SCRIPT'S OWN home,
#     which is the part a consumer changes.
#
#     Asserted as a pair, and the pair is the point. A guard that consulted its surroundings instead
#     of -C would answer from whatever repo it found and wave the consumer's repo through looking
#     exactly like a pass — so "refuses the unignored repo" is only meaningful next to "passes the
#     one that is configured". Neither half alone rules that out.
away="$WORK/plugin-cache/scripts"               # outside any git repo, like an installed plugin —
mkdir -p "$away"                                # and under $WORK, so the EXIT trap still cleans it up
cp "$KIT/$GUARD" "$away/worktrees-ignored.sh"
git -C "$(dirname "$(dirname "$away")")" rev-parse --git-dir >/dev/null 2>&1 \
  && { echo "FAIL [installed-elsewhere]: the fixture is inside a git repo — it proves nothing"; exit 1; }

dir=$(scratch '')                                # a consumer repo with no rule at all
rc=0; ( cd / && bash "$away/worktrees-ignored.sh" -C "$dir" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 1 ] || {
  echo "FAIL [installed-elsewhere]: expected exit 1 for an unignored consumer repo, got $rc"; exit 1; }

rc=0; ( cd / && bash "$away/worktrees-ignored.sh" -C "$KIT" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 0 ] || {
  echo "FAIL [installed-elsewhere]: a correctly configured repo was refused (exit $rc) — control invalid"; exit 1; }
echo "  ok: installed-elsewhere — judges the repo at -C, from a copy living outside any git repo"

# 19. -C takes the worktree ROOT. `.claude/worktrees/` contains a slash, so git anchors it and
#     resolves it relative to the directory it is asked about — point the guard at a subdirectory and
#     a perfectly configured repo answers "NOT ignored". Measured, and it reached a caller: the
#     profile probe passed `-C .` after cd-ing into an explicit [dir] argument.
#     `.worktrees/` has no internal slash, so it matches at any depth and hides the bug half the time
#     — which is why this asserts on the anchored home specifically.
dir=$(scratch '.claude/worktrees/\n.worktrees/\n')
mkdir -p "$dir/src/app"
bash "$KIT/$GUARD" -C "$dir" >/dev/null 2>&1 \
  || { echo "FAIL [root-vs-subdir]: the configured repo failed at its root — control invalid"; exit 1; }
rc=0; bash "$KIT/$GUARD" -C "$dir/src/app" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || {
  echo "FAIL [root-vs-subdir]: expected a subdirectory to be refused (exit 1), got $rc."
  echo "  If this now passes, git stopped anchoring the pattern and callers need not pass the root."; exit 1; }
echo "  ok: root-vs-subdir — the anchored home is only satisfied from the worktree root"

# 20. A rule that is in EFFECT but not committed still exits 0 — the path really is ignored for
#     whoever runs this, so the immediate hazard is covered — but it must SAY so, because callers
#     write the answer down. check-ignore is satisfied by .git/info/exclude and core.excludesFile.
dir=$(scratch '')                                # nothing committed
printf '.claude/worktrees/\n.worktrees/\n' >> "$dir/.git/info/exclude"
out=$(bash "$KIT/$GUARD" -C "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [local-exclude]: expected exit 0 (it IS ignored here), got $rc"; exit 1; }
grep -qF 'note:' <<<"$out" \
  || { echo "FAIL [local-exclude]: a machine-local rule passed silently as if committed:"; echo "$out"; exit 1; }
grep -qF '.git/info/exclude' <<<"$out" \
  || { echo "FAIL [local-exclude]: the note does not name where the rule actually lives:"; echo "$out"; exit 1; }
echo "  ok: local-exclude — passes, but names the rule as uncommitted rather than a repo fact"

# 21. The committed case must NOT carry that note, or it means nothing.
dir=$(scratch '.claude/worktrees/\n.worktrees/\n')
git -C "$dir" add .gitignore
git -C "$dir" -c user.email=t@test -c user.name=T commit -qm "ignore worktree homes"
out=$(bash "$KIT/$GUARD" -C "$dir" 2>&1)
grep -qF 'note:' <<<"$out" \
  && { echo "FAIL [committed-rule]: a tracked .gitignore was flagged as undurable:"; echo "$out"; exit 1; }
echo "  ok: committed-rule — a tracked rule carries no durability note"

echo "worktrees-ignored golden test OK"
