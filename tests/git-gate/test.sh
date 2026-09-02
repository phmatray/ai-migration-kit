#!/usr/bin/env bash
# Golden test for the git write-gate — the PreToolUse/Bash hook that routes the three guarded writes
# through the guards and refuses the discards that produced #26 and #280.
#
# Written fail-path-first, the tests/roseline/test.sh shape: a gate whose PASS path is the only one
# exercised proves nothing, and a gate that fails CLOSED anywhere would deadlock every repository
# the plugin is installed in but never used with (ADR 0002). So every case drives the real script
# over a synthetic PreToolUse payload — that payload is the gate's entire input contract — and the
# allow half of the matrix is as long as the deny half on purpose.
#
# NOTHING here runs a destructive git command. The deny cases are payload strings; the scratch
# repositories exist only so the profile probe has something real to answer about.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
kit_guard kit_guard_samples_unchanged

GATE="$KIT/hooks/git-write-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# The scratch repositories the probe answers about. mktemp -d, NOT a counter: `n=$((n+1))` inside a
# $(...) helper increments a subshell's copy and every "fresh" repo would be the same directory —
# the trap tests/_lib.sh documents and tests/roseline/test.sh already tripped over.
#
# `git init` only; nothing is ever committed and no working tree is ever mutated. The probe reads
# `rev-parse --show-toplevel` plus one `[ -f ]`, which is all these fixtures have to satisfy.
profile_repo() {
  local d; d=$(mktemp -d "$WORK/prof.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  mkdir -p "$d/.claude/skills"
  : > "$d/.claude/skills/repo-profile.md"
  printf '%s' "$d"
}
plain_repo() {
  local d; d=$(mktemp -d "$WORK/plain.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  : > "$d/README.md"
  printf '%s' "$d"
}

# A PATH holding exactly what the gate shells out to, plus whichever stubs are named — built by
# NAMING the tools rather than by subtracting one from $PATH, so the "absent" case holds on every
# host. Every extra argument becomes an empty executable.
shim_path() { # $1 destination dir; $2… stub names
  local d="$1" c p; shift
  mkdir -p "$d"
  for c in bash cat jq awk git tr printf sed; do
    p=$(command -v "$c" 2>/dev/null) || continue
    ln -s "$p" "$d/$c" 2>/dev/null || true
  done
  for c in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"; done
  printf '%s' "$d"
}

pay() { # $1 tool  $2 command  $3 cwd
  jq -nc --arg t "$1" --arg c "$2" --arg d "$3" \
    '{session_id:"gitgate", cwd:$d, tool_name:$t, tool_input:{command:$c}}'
}

# Drives the gate with a synthetic payload. Asserts the exit status, the decision, and — when
# denying — that the reason names the replacement.
# $1 name  $2 expected ("deny"|"pass")  $3 substring the reason must contain  $4 payload
# $5 optional PATH  $6 optional GIT_GATE value
verdict() {
  local name="$1" want="$2" want_msg="$3" payload="$4" gate_path="${5:-$PATH}" sw="${6:-}"
  local out decision rc=0
  if [ -n "$sw" ]; then
    out=$(printf '%s' "$payload" | env PATH="$gate_path" GIT_GATE="$sw" bash "$GATE" 2>/dev/null) || rc=$?
  else
    out=$(printf '%s' "$payload" | env PATH="$gate_path" bash "$GATE" 2>/dev/null) || rc=$?
  fi
  # Exit status is half the PreToolUse contract — a non-zero exit blocks the tool regardless of
  # stdout, so a regression that turned a fail-open path into `exit 2` would be scored "pass" here
  # while blocking every Bash call in production. Matt's script is exactly that shape (`exit 2`).
  [ "$rc" -eq 0 ] || { echo "FAIL [$name]: gate exited $rc; its contract is always exit 0"; exit 1; }
  if [ -z "$out" ]; then decision="pass"; else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed)
  fi
  if [ "$decision" != "$want" ]; then
    echo "FAIL [$name]: expected $want, got $decision"; echo "$out"; exit 1
  fi
  if [ -n "$want_msg" ]; then
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' \
      | grep -qF -e "$want_msg" || { echo "FAIL [$name]: reason lacks '$want_msg'"; echo "$out"; exit 1; }
      # `-e`, not a bare argument: half the replacements this suite asserts start with `--`
      # (`--force-with-lease`), and grep would read those as its own options.
  fi
  echo "ok: $name -> $decision"
}

PROF=$(profile_repo); PLAIN=$(plain_repo)
[ "$PROF" != "$PLAIN" ] || { echo "FAIL: fixture helpers returned the same directory"; exit 1; }

# ------------------------------------------------------- 1. the deny rows, in a profiled repo (D)
verdict "D1  checkout <ref> -- ."      deny "checkout -- <path>" "$(pay Bash 'git checkout main -- .' "$PROF")"
verdict "D2  checkout ."               deny "checkout -- <path>" "$(pay Bash 'git checkout .' "$PROF")"
verdict "D3  restore --staged --worktree ." deny "git restore <path>" "$(pay Bash 'git restore --staged --worktree .' "$PROF")"
verdict "D4  reset --hard"             deny "git reset --keep"   "$(pay Bash 'git reset --hard HEAD~1' "$PROF")"
verdict "D5  clean -fd"                deny "git clean -n"       "$(pay Bash 'git clean -fd' "$PROF")"
verdict "D6  push --force"             deny "--force-with-lease" "$(pay Bash 'git push --force origin main' "$PROF")"
verdict "D7  bare commit"              deny "guarded-commit.sh"  "$(pay Bash 'git commit -m wip' "$PROF")"
verdict "D8  bare push"                deny "guarded-push.sh"    "$(pay Bash 'git push' "$PROF")"
verdict "D9  -c option skipping"       deny "guarded-commit.sh" \
  "$(pay Bash 'git -c user.email=x -c user.name=y commit -m x' "$PROF")"
verdict "D10 the write is segment 2"   deny "git reset --keep"   "$(pay Bash 'cd sub && git reset --hard' "$PROF")"
# The `-C` path names the repository the command acts on, so it outranks the payload's cwd: a push
# into a profiled repo is that repo's push no matter where the shell happens to be standing.
verdict "D11 -C path outranks cwd"     deny "guarded-push.sh"    "$(pay Bash "git -C $PROF push" "$PLAIN")"
verdict "D12 bare merge"               deny "guarded-merge.sh"   "$(pay Bash 'git merge origin/main' "$PROF")"
verdict "D13 clean --force"            deny "git clean -n"       "$(pay Bash 'git clean --force -d' "$PROF")"
verdict "D14 push -f"                  deny "--force-with-lease" "$(pay Bash 'git push -f' "$PROF")"

# ------------------------------------------------ 1b. meaning, not spelling (#373)
# Each of these is the SAME whole-tree discard as a row above, typed differently — a `./` for `.`,
# a bundled `-fq` for `-f`, a `-note` file name after `--` — and every one of them measured as
# allowed before the arms read a normalised argv. #26's originating incident was literally
# `git checkout <ref> -- .`; `git checkout HEAD -- ./` sailing through was that class, not a nit.
verdict "D15 checkout ./"              deny "checkout -- <path>" "$(pay Bash 'git checkout ./' "$PROF")"
verdict "D16 checkout HEAD -- ./"      deny "checkout -- <path>" "$(pay Bash 'git checkout HEAD -- ./' "$PROF")"
verdict "D17 checkout -fq (bundled)"   deny "checkout -- <path>" "$(pay Bash 'git checkout -fq main' "$PROF")"
verdict "D18 switch -fc (bundled)"     deny "checkout -- <path>" "$(pay Bash 'git switch -fc newb' "$PROF")"
verdict "D19 restore ./"               deny "git restore <path>" "$(pay Bash 'git restore ./' "$PROF")"
verdict "D20 clean -fd -- -note"       deny "git clean -n"       "$(pay Bash 'git clean -fd -- -note' "$PROF")"
verdict "D21 checkout -- :/"           deny "checkout -- <path>" "$(pay Bash 'git checkout -- :/' "$PROF")"

# ------------------------------------------------------------------ 2. the allow rows (A)
verdict "A1  branch -D after a merge"  pass "" "$(pay Bash 'git branch -D feat/326-x' "$PROF")"
verdict "A2  checkout a branch"        pass "" "$(pay Bash 'git checkout main' "$PROF")"
verdict "A3  switch"                   pass "" "$(pay Bash 'git switch -c feat/x' "$PROF")"
verdict "A4  restore one named path"   pass "" "$(pay Bash 'git restore src/App.cs' "$PROF")"
verdict "A5  checkout -- one path"     pass "" "$(pay Bash 'git checkout -- src/App.cs' "$PROF")"
verdict "A6  stash -u"                 pass "" "$(pay Bash 'git stash -u' "$PROF")"
verdict "A7  rebase"                   pass "" "$(pay Bash 'git rebase main' "$PROF")"
verdict "A8  reset without --hard"     pass "" "$(pay Bash 'git reset --soft HEAD~1' "$PROF")"
verdict "A9  read-only git"            pass "" "$(pay Bash 'git log --oneline -5 && git status --porcelain' "$PROF")"
verdict "A10 clean -n looks only"      pass "" "$(pay Bash 'git clean -n' "$PROF")"
verdict "A11 merge --abort"            pass "" "$(pay Bash 'git merge --abort' "$PROF")"
verdict "A12 no git in the command"    pass "" "$(pay Bash 'ls -la && rm -rf build' "$PROF")"
# Read-only, or less destructive than the replacement a deny would name (#373): `--staged .`
# unstages and touches no file in the tree; a dry-run push pushes nothing. Both were denied while
# the arms matched spellings, and D3's old form pinned the first one as correct.
verdict "A36 restore --staged . touches no tree file" pass "" "$(pay Bash 'git restore --staged .' "$PROF")"
verdict "A37 push --dry-run"           pass "" "$(pay Bash 'git push --dry-run' "$PROF")"
verdict "A38 push -n"                  pass "" "$(pay Bash 'git push -n' "$PROF")"

# The guards are the whole point: a line that calls one is allowed, INCLUDING the `--force-with-lease`
# the gate refuses on a bare push. Spelled with the quoted `"$GUARDS/…"` every skill actually emits,
# which is why the recognition reads the raw command and not the quote-stripped one.
verdict "A13 guarded-commit.sh line"   pass "" \
  "$(pay Bash '"$GUARDS/guarded-commit.sh" -C "$WORKTREE" -c user.email=a@b -c user.name="A B" main -- -am msg' "$PROF")"
verdict "A14 guarded-push --force-with-lease" pass "" \
  "$(pay Bash '"$GUARDS/guarded-push.sh" -C "$WORKTREE" main -- --force-with-lease' "$PROF")"
verdict "A15 guarded-merge.sh line"    pass "" \
  "$(pay Bash '"$GUARDS/guarded-merge.sh" -C "$WORKTREE" main -- origin/main' "$PROF")"
verdict "A16 guarded-pr-merge.sh line" pass "" \
  "$(pay Bash '"$GUARDS/guarded-pr-merge.sh" 353' "$PROF")"

# Matt's substring greps deny both of these (mattpocock/skills, MIT — prior art, not a port).
verdict "A17 inside a double-quoted string" pass "" "$(pay Bash 'echo "git push --force"' "$PROF")"
verdict "A18 inside a single-quoted string" pass "" "$(pay Bash "printf '%s' 'git reset --hard'" "$PROF")"
verdict "A19 after a # comment"        pass "" "$(pay Bash 'git log --oneline # git reset --hard' "$PROF")"

# --------------------------------------- 2b. the shapes a first tokeniser got wrong (R)
# Every case here is a behaviour a code review REPRODUCED against the first implementation, kept as
# a regression row rather than a note. Together they are the bulk of what an agent actually types.

# `git -C "$WORKTREE" …` is what this kit's own references prescribe over `cd … &&`, and it is the
# dominant idiom across skills/. Deleting the quoted span instead of standing a token in its place
# made `-C` swallow the subcommand, so the gate was blind to the exact incident class it exists for.
verdict "R1  git -C \"quoted\" commit"  deny "guarded-commit.sh" \
  "$(pay Bash 'git -C "$WORKTREE" commit -m "wip"' "$PROF")"
# ...and unquoted, with the variable the hook cannot expand: an unresolvable `-C` is no evidence, so
# the probe falls back to cwd rather than treating it as "not a profiled repo".
verdict "R2  -C names an unresolvable path" deny "guarded-commit.sh" \
  "$(pay Bash 'git -C $WORKTREE commit -m wip' "$PROF")"
# ...whereas a `-C` that DOES resolve, to a repo without a profile, still means what it says.
verdict "R3  -C resolves to an unprofiled repo" pass "" \
  "$(pay Bash "git -C $PLAIN commit -m wip" "$PROF")"

# Grouping and control flow: `(`, `{`, `then`, `do`. A bare write wrapped in any of them used to
# stop the prefix walk on its first token and never be judged at all.
verdict "R4  subshell"                 deny "guarded-commit.sh" "$(pay Bash '(git commit -m x)' "$PROF")"
verdict "R5  brace group"              deny "guarded-commit.sh" "$(pay Bash '{ git commit -m x; }' "$PROF")"
verdict "R6  inside an if"             deny "guarded-commit.sh" "$(pay Bash 'if true; then git commit -m x; fi' "$PROF")"
verdict "R7  inside a for"             deny "guarded-push.sh"   "$(pay Bash 'for f in a b; do git push; done' "$PROF")"

# `#` is a comment only at a word boundary, as in real shell — and the comment ends at the next
# separator, so it can never swallow a command that really would run.
verdict "R8  a # inside a word hides nothing" deny "git reset --keep" \
  "$(pay Bash 'git log --grep=a#b && git reset --hard' "$PROF")"

# The force flags are the same whole-tree discard as a `.` pathspec, spelled without one.
verdict "R9  checkout -f"              deny "git checkout -- <path>" "$(pay Bash 'git checkout -f main' "$PROF")"
verdict "R10 switch --discard-changes" deny "git checkout -- <path>" "$(pay Bash 'git switch --discard-changes main' "$PROF")"

# `git clean -ndf` deletes nothing — it is the command the deny reason recommends, so denying it
# would send the reader in a circle.
verdict "R11 clean -ndf is a dry run"  pass "" "$(pay Bash 'git clean -ndf' "$PROF")"

# A heredoc body is FILE CONTENT. Denying it would make it impossible to WRITE a script, doc or
# test whose text contains one of these lines — which this repository's own suites do — so a
# command carrying `<<` is a parse the gate does not trust, and it fails open.
verdict "R12 a heredoc body is not a command" pass "" \
  "$(pay Bash "cat > t.sh <<'SH'
git commit -m x
SH" "$PROF")"

# ---------------------------------------------------- 3. inert where the guards cannot exist
# The probe's whole argument (the `dnx` argument of #112, transposed): a denial names a
# `guarded-*.sh` replacement, so it must not fire where that replacement does not exist.
verdict "A20 no profile, no denial"    pass "" "$(pay Bash 'git checkout main -- .' "$PLAIN")"
verdict "A21 no profile, bare commit"  pass "" "$(pay Bash 'git commit -m wip' "$PLAIN")"

# The probe follows a literal `cd` (#372): a write after `cd <guard-less repo>` is that repository's
# write, and denying it names guards that do not exist there. A41 is docs/demo-walkthrough.md's own
# reproduce line — the directory it cds into is created by the `cp` in the same command, so the
# `cd` cannot be resolved; the `git init` that follows is what tells the gate the later segments
# act in a brand-new repository.
verdict "A40 cd into a guard-less repo" pass "" "$(pay Bash "cd $PLAIN && git commit -m x" "$PROF")"
verdict "A41 cp, cd, init, commit (the walkthrough line)" pass "" \
  "$(pay Bash "cp -r samples/LegacyShop $PLAIN/shop && cd $PLAIN/shop && git init && git add -A && git commit -m legacy" "$PROF")"
verdict "A42 GIT_GATE=off as a one-command prefix" pass "" "$(pay Bash 'GIT_GATE=off git commit -m x' "$PROF")"
# ...and every cd the hook cannot resolve leaves the probe where it was: a variable, `~`, `cd -`,
# a bare `cd`, `pushd`, and a `cd` inside `( … )` whose directory change dies with the subshell.
verdict "D23 cd \$VAR stays put"        deny "guarded-commit.sh" "$(pay Bash 'cd $ELSEWHERE && git commit -m x' "$PROF")"
verdict "D24 cd ~ stays put"           deny "guarded-commit.sh" "$(pay Bash 'cd ~/elsewhere && git commit -m x' "$PROF")"
verdict "D25 cd - stays put"           deny "guarded-commit.sh" "$(pay Bash 'cd - && git commit -m x' "$PROF")"
verdict "D26 bare cd stays put"        deny "guarded-commit.sh" "$(pay Bash 'cd && git commit -m x' "$PROF")"
verdict "D27 pushd stays put"          deny "guarded-commit.sh" "$(pay Bash "pushd $PLAIN && git commit -m x" "$PROF")"
verdict "D28 a cd inside ( ) dies with its subshell" deny "guarded-commit.sh" \
  "$(pay Bash "(cd $PLAIN) && git commit -m x" "$PROF")"
verdict "D29 cd INTO a profiled repo"  deny "guarded-commit.sh" "$(pay Bash "cd $PROF && git commit -m x" "$PLAIN")"
# The deny text names the two escapes that work and no longer the one that did nothing (#372): an
# `export` typed into a Bash call never reaches a hook the Claude Code process spawns.
reason=$(pay Bash 'git commit -m wip' "$PROF" | bash "$GATE" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
grep -qF 'GIT_GATE=off git' <<<"$reason" \
  || { echo "FAIL: the deny text does not name the per-command GIT_GATE=off prefix"; exit 1; }
grep -qF 'launch Claude with GIT_GATE=off' <<<"$reason" \
  || { echo "FAIL: the deny text does not say the session switch is set where Claude is launched"; exit 1; }
if grep -qF 'for one command or for the session' <<<"$reason"; then
  echo "FAIL: the deny text still advertises an off-switch that does nothing from inside a session (#372)"; exit 1
fi
echo "ok: the deny text names only the escapes that work"
# ...and the pair is a MEASUREMENT rather than a coincidence: the same command in the profiled repo
# denies (D1 above), so A20's pass can only be the probe and not some other fail-open path.

# --------------------------------------------------------------- 4. the switches (off wins)
verdict "A22 GIT_GATE=off"             pass "" "$(pay Bash 'git checkout main -- .' "$PROF")" "$PATH" off
verdict "A23 GIT_GATE=on forces past the probe" deny "checkout -- <path>" \
  "$(pay Bash 'git checkout main -- .' "$PLAIN")" "$PATH" on
verdict "A24 off outranks a probe that would deny" pass "" \
  "$(pay Bash 'git commit -m wip' "$PROF")" "$PATH" off
verdict "A25 an unrecognised value falls through" pass "" \
  "$(pay Bash 'git checkout main -- .' "$PLAIN")" "$PATH" maybe

# GIT_GATE holds one value, so `off` and `on` cannot literally both be set; what the spec calls "off
# wins" is the ORDER of the two branches inside the gate. Asserted at the source, because that order
# is the only place the invariant exists: with `on` first, a stale `on` in a shell rc would quietly
# override the `off` a user just typed.
off_line=$(grep -n 'off|0|false|no|disabled' "$GATE" | head -1 | cut -d: -f1)
on_line=$(grep -n 'on|1|true|yes|enabled' "$GATE" | head -1 | cut -d: -f1)
[ -n "$off_line" ] && [ -n "$on_line" ] \
  || { echo "FAIL: the gate does not carry both switch branches (off=$off_line on=$on_line)"; exit 1; }
[ "$off_line" -lt "$on_line" ] \
  || { echo "FAIL: the 'on' branch (line $on_line) precedes 'off' (line $off_line); off must stay the master switch"; exit 1; }
echo "ok: the off branch is checked before the on branch"

# --------------------------------------------------------- 5. every internal failure fails OPEN
NOJQ=$(shim_path "$WORK/nojq"); rm -f "$NOJQ/jq"
NOAWK=$(shim_path "$WORK/noawk"); rm -f "$NOAWK/awk"
NOGIT=$(shim_path "$WORK/nogit"); rm -f "$NOGIT/git"
FULL=$(shim_path "$WORK/full")

verdict "A26 no jq on PATH"            pass "" "$(pay Bash 'git commit -m wip' "$PROF")" "$NOJQ"
verdict "A27 no awk on PATH"           pass "" "$(pay Bash 'git commit -m wip' "$PROF")" "$NOAWK"
verdict "A28 no git on PATH"           pass "" "$(pay Bash 'git commit -m wip' "$PROF")" "$NOGIT"
# The control for the three above: the SAME stripped PATH, complete, must still deny — otherwise
# each pass is equally well explained by the shim missing something the gate needs, and section 5
# would be green while measuring nothing.
verdict "A29 the same shim, complete, still denies" deny "guarded-commit.sh" \
  "$(pay Bash 'git commit -m wip' "$PROF")" "$FULL"

verdict "A30 malformed payload"        pass "" 'not json at all'
verdict "A31 a tool other than Bash"   pass "" "$(pay NotebookEdit 'git commit -m wip' "$PROF")"
verdict "A32 BashOutput is not Bash"   pass "" "$(pay BashOutput 'git commit -m wip' "$PROF")"
verdict "A33 no command in the payload" pass "" '{"tool_name":"Bash","cwd":"/tmp","tool_input":{}}'
verdict "A34 unterminated quoting is a parse it cannot trust" pass "" \
  "$(pay Bash 'git commit -m "never closed' "$PROF")"
# A command past the size cap is not one of the shapes above; parsing it would outrun the hook's
# 5s timeout, and a timed-out hook is an unpredictable one. The padding goes AFTER an intact
# `git commit -m x`, so the tokeniser has a real write to find: the first spelling ran the whole
# line through `tr ' ' 'y'`, spaces included, and left no `git` token at all — with the cap
# deleted, A35 stayed green and measured nothing (#373).
BIG="git commit -m x $(printf '%*s' 70000 '' | tr ' ' 'y')"
verdict "A35 an oversized command"     pass "" "$(pay Bash "$BIG" "$PROF")"

# ---------------------------------------------------------------- 6. structural wiring (S)
# S1 — hooks are outside parse-sweep's default target set (docs/backlog.md records that gap), so the
# sweep is invoked on this file explicitly. bash 3.2 is the floor the sweep enforces.
./scripts/parse-sweep.sh hooks/git-write-gate.sh tests/git-gate/test.sh >/dev/null \
  || { echo "FAIL: parse-sweep rejects the gate or this suite"; exit 1; }
echo "ok: the gate and this suite pass ./scripts/parse-sweep.sh"

# S2 — the registration. A hook that is never invoked looks exactly like a hook that found nothing
# to block, which is the failure scripts/ci-wiring-check.py exists for one level up.
HJ="$KIT/hooks/hooks.json"
jq -e . "$HJ" >/dev/null 2>&1 || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }
n=$(jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length' "$HJ")
[ "$n" = "1" ] || { echo "FAIL: hooks.json has $n Bash matchers, want exactly 1"; exit 1; }
got=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$HJ")
case "$got" in
  *'${CLAUDE_PLUGIN_ROOT}'*git-write-gate.sh) echo "ok: hooks.json wires Bash -> $got" ;;
  *) echo "FAIL: Bash matcher command is '$got'; must reference \${CLAUDE_PLUGIN_ROOT}/hooks/git-write-gate.sh"; exit 1 ;;
esac
tmo=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].timeout // empty' "$HJ")
[ -n "$tmo" ] || { echo "FAIL: the Bash hook has no timeout; a hung gate would stall every Bash call"; exit 1; }
resolved="${got/\$\{CLAUDE_PLUGIN_ROOT\}/$KIT}"
[ -x "$resolved" ] || { echo "FAIL: hooks.json points at '$resolved', which is not an executable file"; exit 1; }
echo "ok: the registered command resolves to a shipped executable with timeout=$tmo"

# The Read matcher must survive this PR untouched — the two hooks share one file, and the roseline
# gate going missing would be invisible to every case above.
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Read")] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one Read matcher"; exit 1; }
echo "ok: the roseline gate's Read matcher is still registered"

# S3 — the registry entry. `scripts/decision-check.py`'s R10 does not enumerate `hooks/` today
# (#307 will widen it); recording the entry now is what makes that widening land green instead of
# red, and it is the class the four `guarded-*.sh` scripts are already recorded under.
python3 - "$KIT/decisions/registry.json" <<'PY' || exit 1
import json, sys
reg = json.load(open(sys.argv[1]))
nd = reg.get("not_decisions", {})
key = "hooks/git-write-gate.sh"
if key not in nd:
    print(f"FAIL: decisions/registry.json not_decisions has no entry for {key}")
    sys.exit(1)
if not nd[key].strip():
    print(f"FAIL: the not_decisions entry for {key} is empty; it must say WHY")
    sys.exit(1)
print(f"ok: decisions/registry.json records {key} under not_decisions")
PY

# S4 — the prerequisite. Without `jq` the hook exits at its first probe and enforcement is silently
# off, so the manifest has to name this gate too, not just the roseline one.
REQ="$KIT/requirements.json"
hint=$(jq -r '.tools[] | select(.name | test("jq")) | .hint' "$REQ")
printf '%s' "$hint" | grep -qF 'git-write-gate.sh' \
  || { echo "FAIL: requirements.json's jq hint does not mention hooks/git-write-gate.sh: '$hint'"; exit 1; }
echo "ok: requirements.json's jq hint names both gates"

# S5 — the documentation. An off-switch nobody can find is not an off-switch.
grep -qF 'git-write-gate' "$KIT/README.md" \
  || { echo "FAIL: README does not document the git write-gate"; exit 1; }
grep -qF 'GIT_GATE=off' "$KIT/README.md" \
  || { echo "FAIL: README does not document GIT_GATE=off"; exit 1; }
echo "ok: README documents the gate and its off-switch"

# S6 — the prior-art credit. Matt Pocock's block-dangerous-git.sh (mattpocock/skills, MIT) is the
# idea's source and is deliberately not copied; the file has to say both.
grep -qF 'mattpocock/skills' "$GATE" \
  || { echo "FAIL: the gate does not credit mattpocock/skills as prior art"; exit 1; }
echo "ok: the gate credits its prior art"

echo "git write-gate golden test OK"
