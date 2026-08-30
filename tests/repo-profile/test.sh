#!/usr/bin/env bash
# Golden test for repo-profile.sh (rule 7: mandatory tool → mandatory test).
# Covers show's two paths (profile present / NO_PROFILE) and detect's contract:
# every field a probe cannot answer prints a TODO line instead of silent emptiness.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
SCRIPT="skills/get-repo-profile/scripts/repo-profile.sh"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# Decided, not omitted — tests/_lib.sh's contract asks a converted suite to say either way, so that
# "forgot" and "does not apply" stop looking alike. This one runs a kit script that WRITES profiles,
# pointed at scratch repos; the guard is what proves it never wrote into the frozen fixture instead.
kit_guard kit_guard_samples_unchanged

fail() { echo "FAIL: $1"; exit 1; }

# Every scratch directory below comes from the shared helper, so all of them are removed on EVERY
# exit path (#128). They used to be freed by one `rm -rf` on the last line, which the `fail()` above
# skips past — so any red run of this suite stranded up to five directories, and the assertion that
# fired earliest stranded the most.

# 1. show without a profile → prints NO_PROFILE, exits 3.
tmp=$(kit_scratch)
rc=0; out=$(bash "$SCRIPT" show "$tmp") || rc=$?
[ "$rc" -eq 3 ] || fail "show without profile: expected exit 3, got $rc"
[ "$out" = "NO_PROFILE" ] || fail "show without profile: expected NO_PROFILE, got '$out'"

# 2. show with a profile → prints it back verbatim, exits 0.
mkdir -p "$tmp/.claude/skills"
printf '# Repo profile\n- fixture\n' > "$tmp/.claude/skills/repo-profile.md"
[ "$(bash "$SCRIPT" show "$tmp")" = "$(cat "$tmp/.claude/skills/repo-profile.md")" ] \
  || fail "show with profile: output differs from the committed file"

# 3. detect outside a git repository → exits 4.
tmp2=$(kit_scratch)
rc=0; bash "$SCRIPT" detect "$tmp2" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "detect outside git: expected exit 4, got $rc"

# 4. detect in a bare-bones git repo (no CLAUDE.md, no README, no remote, no workflows):
#    all sections present AND the TODO fallbacks actually fire — this is the regression
#    guard for the `pipeline || echo TODO` dead-fallback bug.
repo=$(kit_scratch)
git -C "$repo" init -q
git -C "$repo" -c user.email=t@test -c user.name=T commit -q --allow-empty -m "init"
out=$(bash "$SCRIPT" detect "$repo")
for s in "## Identity" "## Commit identity" "## Build system" "## CI gates" \
         "## Integration style" "## Labels" "## Issue templates" \
         "## Tracker" "## Domain language" "## ADRs" "## Out-of-scope records" \
         "## Coding standards" "## Architecture grain"; do
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

# 4b. The five v2.0 sections (#311): absence is a VERDICT ("none"), not a TODO, for four of them —
#     only the Tracker probe can genuinely fail to reach a verdict (no remote at all).
section_of() { awk -v h="## $2" '$0==h{f=1;next} /^## /{f=0} f' <<<"$1"; }

grep -qF "TODO: no origin remote — cannot name the tracker" <<<"$out" \
  || fail "detect: Tracker TODO fallback did not fire on a repo with no origin remote:
$out"

sec=$(section_of "$out" "Domain language")
grep -qF "none" <<<"$sec" || fail "detect: Domain language did not fall back to 'none':
$sec"

sec=$(section_of "$out" "ADRs")
grep -qF "root: none" <<<"$sec" || fail "detect: ADRs root did not fall back to 'none':
$sec"

sec=$(section_of "$out" "Out-of-scope records")
grep -qF "none" <<<"$sec" || fail "detect: Out-of-scope records did not fall back to 'none':
$sec"

sec=$(section_of "$out" "Coding standards")
grep -qF "none" <<<"$sec" || fail "detect: Coding standards did not fall back to 'none':
$sec"

# 4c. The five v2.0 headers `detect` prints must also appear, verbatim, in the SCHEMA block of
#     references/profile-template.md — not the worked example below it — so the writer (`detect`)
#     and the reader's schema cannot drift apart the way #157 warned about for the older sections.
#     Scoped to the schema fence (between "## The schema" and "## Worked example"): the worked
#     example repeats "## Identity" etc. for a DIFFERENT repo, and a whole-file grep would let a
#     header that only ever appears there pass as if it were part of the contract.
TEMPLATE="$KIT/skills/get-repo-profile/references/profile-template.md"
schema_block=$(awk '/^## The schema/{f=1} f{print} /^## Worked example/{exit}' "$TEMPLATE")
for s in "## Tracker" "## Domain language" "## ADRs" "## Out-of-scope records" "## Coding standards"; do
  grep -qF "$s" <<<"$schema_block" \
    || fail "profile-template.md's schema block is missing the '$s' header detect now prints — the
      writer and the schema have drifted apart (#311)"
done

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

wt=$(kit_scratch)
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
wt2=$(kit_scratch)
git -C "$wt2" init -q
git -C "$wt2" -c user.email=t@test -c user.name=T commit -q --allow-empty -m "init"
printf '.claude/worktrees/\n.worktrees/\n' >> "$wt2/.git/info/exclude"
sec=$(wt_section "$(bash "$SCRIPT" detect "$wt2")")
grep -qF 'ignored on this machine only' <<<"$sec" \
  || fail "detect: a machine-local rule was recorded as a property of the repo:
$sec"

# 5e. THE fail-open case (#125): asked from inside a LINKED worktree — the normal state during
#     implement-issue/merge-pr — the probe must judge the MAIN checkout, never the worktree it
#     happens to be invoked from. Reproduces exactly the shape
#     tests/worktrees-ignored/test.sh case 22 pins for the guard itself: the ignore rule was
#     committed, then dropped from the main working tree, while a linked worktree's own checked-out
#     .gitignore (from the earlier commit) still carries it.
wt3=$(kit_scratch)
git -C "$wt3" init -q -b main
git -C "$wt3" config user.email t@example.com
git -C "$wt3" config user.name "Golden Test"
printf '.claude/worktrees/\n.worktrees/\n' > "$wt3/.gitignore"
git -C "$wt3" add -A
git -C "$wt3" commit -qm base
git -C "$wt3" worktree add -q .claude/worktrees/feat -b feat
LINKED="$wt3/.claude/worktrees/feat"

# Drop the rule from the MAIN working tree only — nothing about the linked worktree's own files
# changes, so a probe reading THAT checkout's .gitignore still finds the (now stale) rule.
: > "$wt3/.gitignore"

sec=$(wt_section "$(bash "$SCRIPT" detect "$LINKED")")
grep -qF 'ignore status verified' <<<"$sec" \
  && fail "detect: judged the LINKED worktree instead of the main checkout — the main checkout's
      own ignore rule was dropped, so 'ignore status verified' is a false pass (#125):
$sec"

# 5f. main-worktree.sh can fail for a reason that has NOTHING to do with bareness (a corrupted
#     `.git/worktrees` admin area, a permissions error) — exit non-zero with empty stdout, same as
#     the documented bare-repo signal. The probe must tell those apart by exit code, not by treating
#     every empty `$wt_root` as "verified bare, nothing to check"; a real failure must surface as a
#     TODO, never silently read as "no hazard here".
STUB="$(kit_scratch)"
MARKER="$(kit_scratch)/worktree-list-was-called"
REAL_GIT=$(command -v git)
cat > "$STUB/git" <<STUBEOF
#!/bin/sh
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "list" ]; then
  echo called >> "$MARKER"
  echo "fake git: worktree list failed" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
STUBEOF
chmod +x "$STUB/git"

sec=$(wt_section "$(PATH="$STUB:$PATH" bash "$SCRIPT" detect "$wt")")
[ -s "$MARKER" ] \
  || fail "detect: the stub git was never reached — this case reproduces nothing"
grep -qF 'bare repository' <<<"$sec" \
  && fail "detect: a non-bare 'git worktree list' failure was reported as a verified bare repo —
      exit code was not checked, so a real failure reads as \"nothing to check\":
$sec"
grep -qF 'could not reach a verdict' <<<"$sec" \
  || fail "detect: main-worktree.sh's failure was not surfaced as a TODO:
$sec"

# 6. THIS repository's own profile must be TRACKED (#157). Every case above fixtures a profile into
#    a scratch repo, so all of them passed while the kit itself carried none: the file existed in
#    exactly one checkout and reached no clone, no CI job and — the common case — no linked worktree,
#    where a lifecycle skill then read empty output and inferred the repo's facts instead.
#
#    The kit tells consumer repos to version it (get-repo-profile: "Run once per repo, commit the
#    profile"), .gitignore says so in its own comment, and scripts/worktrees-ignored.sh reserves this
#    exact path as MUST_STAY_VISIBLE — a guard with a dedicated exit code for "your ignore rule is
#    too broad to carry a committed profile", shipped by a repo that never committed one.
#
#    `ls-files --error-unmatch` and not `[ -f ]`: on disk is not the property under test — the file
#    was on disk in the generating checkout the whole time. Tracked is what makes it travel.
PROFILE=".claude/skills/repo-profile.md"

# "Tracked" is only a question a git repository can answer, and `ls-files` outside one exits 128
# with the same empty stdout as an untracked file — which the assertion below would report as "the
# profile is not tracked", stating as measured fact something never measured (#129). Separate the
# two, so an unrunnable case reads as unrunnable.
git -C "$KIT" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "the kit root $KIT is not a git repository, so whether $PROFILE is TRACKED cannot be
      measured from here. That is a missing precondition, not a passing case"

git -C "$KIT" ls-files --error-unmatch -- "$PROFILE" >/dev/null 2>&1 \
  || fail "the kit's own $PROFILE is not tracked. get-repo-profile tells consumer repos to commit
      it and worktrees-ignored.sh keeps the path visible for exactly that; generate it with
      \`skills/get-repo-profile/scripts/repo-profile.sh detect\` FROM THE MAIN WORKING TREE (#125:
      a linked worktree records a false ignore verdict) and commit the result"

# Tracked but empty would satisfy the line above and still leave every skill inferring, so assert the
# content the lifecycle skills actually open the file for. One section, named in the template's
# schema — enough to prove a filled profile, few enough not to re-test get-repo-profile's own output.
grep -qF '## Commit identity' "$KIT/$PROFILE" \
  || fail "$PROFILE is tracked but carries no '## Commit identity' section — the lifecycle skills
      read it there; fill the schema in skills/get-repo-profile/references/profile-template.md"

# 7. No skill reads the profile with a bare `cat` (#157). The helper's whole reason to exist is that
#    it distinguishes "absent" from "empty": `show` prints NO_PROFILE and exits 3 (case 1 above),
#    while a bare cat writes one line to STDERR, nothing to stdout, and returns a status the reading
#    agent never sees — so a repo with no profile looks exactly like a repo whose profile is silent,
#    and the skill infers the facts it was supposed to read. Case 6 makes THIS repo's profile
#    present; this case keeps every consumer repo's absence audible.
#
#    Matched on `cat` immediately followed by the path (an optional prefix such as `"$KIT/` allowed),
#    so the surrounding prose may keep saying the word — the defect is the command, not the noun.
#    It deliberately does NOT try to catch every spelling a determined author could reach for
#    (`cat -- <path>`, a shell variable holding the path); this is a lint against the reflex, and a
#    pattern loose enough to catch those would start matching the paragraphs that explain them.
PROFILE_CAT_RE='cat[[:space:]]+[^[:space:]|]*\.claude/skills/repo-profile\.md'

# grep exits 1 for "searched, found nothing" and 2 for "could not search" — a missing directory, an
# unreadable file — and only the first is a pass. `|| true` collapsed them, so a scan that never ran
# looked exactly like a clean one: the fail-open shape release-title-diff.sh was split out to remove.
[ -d "$KIT/skills" ] || fail "$KIT/skills does not exist, so the bare-cat scan below has nothing to
      search. Refusing to report that as a clean scan"
grep_rc=0
offenders=$(grep -rnE "$PROFILE_CAT_RE" --include='*.md' "$KIT/skills") || grep_rc=$?
[ "$grep_rc" -le 1 ] || fail "the bare-cat scan could not run (grep exit $grep_rc) — that is not a
      verdict, and must not be read as one"
[ -z "$offenders" ] || fail "a skill still reads the profile with a bare cat — use
      \`<kit>/skills/get-repo-profile/scripts/repo-profile.sh show\`, which reports NO_PROFILE/exit 3
      instead of empty output:
$offenders"

# The pattern IS the assertion, so prove it still sees what it looks for: a regex that has stopped
# matching anything would pass the case above forever, silently. Fixture, never the real tree.
probe=$(kit_scratch)
mkdir -p "$probe/skills"
printf 'Read it directly:\n\n```bash\ncat .claude/skills/repo-profile.md\n```\n' \
  > "$probe/skills/decoy.md"
grep -rqE "$PROFILE_CAT_RE" --include='*.md' "$probe/skills" \
  || fail "the bare-cat pattern no longer matches a bare cat — the case above passes vacuously"

# 8. The five v2.0 sections, positive case (#311): a fixture repo carrying a glossary, an ADR
#    root, an out-of-scope directory and a coding-standards marker, with a non-GitHub origin —
#    and the ADRs "server" facet exercised on three separate states of the `claude` binary.
#    PATH is rebuilt from scratch (not prepended) for each variant so a REAL `claude` on this
#    machine's PATH can never leak into the "absent"/"files only" cases.
mkbin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local c p
  for c in "$@"; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    ln -s "$p" "$dir/$c"
  done
}
DETECT_TOOLS="bash git gh grep sed head sort wc find basename cat cut dirname tr"

fx=$(kit_scratch)
git -C "$fx" init -q -b main
git -C "$fx" config user.email t@test
git -C "$fx" config user.name T
printf '# glossary\n' > "$fx/CONTEXT.md"
mkdir -p "$fx/docs/adr" "$fx/docs/out-of-scope"
printf '# ADR 1\n' > "$fx/docs/adr/0001-x.md"
printf 'rejected idea\n' > "$fx/docs/out-of-scope/a.md"
printf '[*]\nindent_style = space\n' > "$fx/.editorconfig"
git -C "$fx" add -A
git -C "$fx" -c user.email=t@test -c user.name=T commit -q -m base
git -C "$fx" remote add origin git@gitlab.example.com:x/y.git

# 8a. No `claude` binary anywhere on PATH.
NOCLAUDE="$(kit_scratch)/bin"
mkbin "$NOCLAUDE" $DETECT_TOOLS
out=$(PATH="$NOCLAUDE" bash "$SCRIPT" detect "$fx")

grep -qF "tracker: other: gitlab.example.com" <<<"$out" \
  || fail "detect: a non-GitHub origin was not reported as 'other: <host>':
$out"
sec=$(section_of "$out" "Domain language")
grep -qF "CONTEXT.md" <<<"$sec" || fail "detect: Domain language lost CONTEXT.md:
$sec"
sec=$(section_of "$out" "ADRs")
grep -qF "root: docs/adr/ (1 files)" <<<"$sec" || fail "detect: ADRs root count wrong:
$sec"
grep -qF "server: files only (claude CLI not found)" <<<"$sec" \
  || fail "detect: ADRs server did not report the missing claude CLI:
$sec"
sec=$(section_of "$out" "Out-of-scope records")
grep -qF "docs/out-of-scope/ (1 files)" <<<"$sec" \
  || fail "detect: Out-of-scope records count wrong:
$sec"
sec=$(section_of "$out" "Coding standards")
grep -qF ".editorconfig" <<<"$sec" || fail "detect: Coding standards lost .editorconfig:
$sec"

# 8b. `claude` present, but `mcp list` names no `adr` server.
NOADR="$(kit_scratch)/bin"
mkbin "$NOADR" $DETECT_TOOLS
cat > "$NOADR/claude" <<'STUBEOF'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  echo "No MCP servers configured."
  exit 0
fi
exit 1
STUBEOF
chmod +x "$NOADR/claude"
sec=$(section_of "$(PATH="$NOADR" bash "$SCRIPT" detect "$fx")" "ADRs")
grep -qF "server: files only (no 'adr' MCP server" <<<"$sec" \
  || fail "detect: ADRs server did not fall back to 'files only' when claude names no adr server:
$sec"

# 8c. `claude` present and `mcp list` names an `adr` (AdrMcp) server — a session/machine fact,
#     never promoted to a claim about the repo.
WITHADR="$(kit_scratch)/bin"
mkbin "$WITHADR" $DETECT_TOOLS
cat > "$WITHADR/claude" <<'STUBEOF'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  echo "adr: dnx AdrMcp@latest  - ✓ Connected"
  exit 0
fi
exit 1
STUBEOF
chmod +x "$WITHADR/claude"
sec=$(section_of "$(PATH="$WITHADR" bash "$SCRIPT" detect "$fx")" "ADRs")
grep -qF "server: via AdrMcp" <<<"$sec" \
  || fail "detect: ADRs server did not report AdrMcp when claude mcp list names 'adr':
$sec"
grep -qF "on this machine only" <<<"$sec" \
  || fail "detect: the AdrMcp server line was not flagged as a machine-local fact, not a repo fact:
$sec"

echo "repo-profile golden test OK"
