#!/usr/bin/env bash
# Git write-gate (Claude Code PreToolUse, matcher: Bash).
#
# The kit knows exactly which git writes hurt in a shared checkout, and until now it said so only in
# prose. #26 (2026-08-10): four agents in one checkout, a concurrent `git checkout` moved HEAD
# between branch creation and commit, the commit landed on the OTHER agent's branch, `git push`
# carried it into that agent's PR, and every command exited 0. The fix was three guards —
# `guarded-commit.sh`, `guarded-push.sh`, `guarded-merge.sh` (plus `guarded-pr-merge.sh` in
# `merge-pr`) — that assert the branch before and after, and a rule that the raw commands are never
# used. #280 is that rule failing again: a worker hand-rolled its own check and committed to the
# user's branch in the main checkout. A rule living in prose cannot go red. This hook is where it
# goes red — the one place in Claude Code that sees the command before it runs.
#
# It fails OPEN, always — the decision recorded in docs/adr/0002-the-roseline-gate-fails-open-always.md
# for `hooks/roseline-gate.sh`, which this hook is modelled on line for line and which applies here
# verbatim: the plugin installs globally, so a Bash gate that failed CLOSED would deadlock every
# repository it was never meant to touch. Every internal failure — no `jq`, no `awk`, no `git`, an
# unparseable payload, a command whose quoting cannot be trusted — exits 0 with no output.
# `GIT_GATE=off` (also `0|false|no|disabled`) is the master switch and is checked FIRST;
# `GIT_GATE=on` forces enforcement past the probe below, and `off` still wins.
#
# ------------------------------------------------------------------------- prior art, not a port
# Matt Pocock ships `git-guardrails-claude-code/scripts/block-dangerous-git.sh` (mattpocock/skills,
# MIT) for the same reason. It is deliberately NOT copied, for four measured reasons:
#   1. it fails CLOSED — `exit 2` on a match, no off-switch, no probe (see the paragraph above);
#   2. it blocks `git push` outright, and this kit's lifecycle pushes on every task THROUGH
#      `guarded-push.sh` — so the gate has to recognise the guard rather than the verb;
#   3. it blocks `git branch -D`, which `merge-pr`'s teardown and `make-worktree.sh`'s cleanup run
#      legitimately on branches whose PR just merged (reflog-recoverable; a branch is not a tree);
#   4. its patterns are substring greps — `"git push"` also fires on `echo "git push"` and on a
#      commit message quoting it, and `push --force` also fires on `--force-with-lease`.
# The idea is worth porting; the script is not. This one tokenises, probes, and routes to the guards.

case "${GIT_GATE:-}" in off|0|false|no|disabled) exit 0 ;; esac

# `on` is checked SECOND, on purpose: `off` stays the master switch, so a stale `on` in a shell rc
# can never override the `off` a user just typed. It forces enforcement past the profile probe below
# — the user's testimony that the lifecycle guards DO apply here — and nothing else. Any other
# value, `maybe` included, is neither switch and falls through to the probe exactly as unset does.
FORCE=0
case "${GIT_GATE:-}" in on|1|true|yes|enabled) FORCE=1 ;; esac

# Word splitting below (`set -- $seg`) is how a segment becomes tokens, and it must not also glob:
# an unquoted `*` in a command would otherwise expand against the hook's own working directory and
# the subcommand could land anywhere in the result.
set -f

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Re-checked even though hooks.json matches "Bash": the matcher is a regex, so it also catches
# BashOutput, and would catch any future tool whose name contains "Bash".
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# A command this long is not one of the shapes below; parsing it would cost more than the hook's
# 5s timeout allows and a timed-out hook is an unpredictable one. Fail open, explicitly.
[ "${#cmd}" -le 65536 ] || exit 0

# The cheap reject, before any parsing: nothing here can matter to a command with no `git` in it.
case "$cmd" in *git*) ;; *) exit 0 ;; esac

cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null) || exit 0

# ------------------------------------------------------------------- strip quotes and comments
# `echo "git push --force"` is not a push, and `git log # git reset --hard` is not a reset. Matt's
# script denies both (reason 4 above). So the command is stripped of quoted spans and comments
# BEFORE anything is matched, and a string whose quoting does not close is a parse this hook cannot
# trust — awk exits 3 and the `||` fails open.
#
# Newlines are folded to `;` first: they are a segment separator like `;` anyway, and doing it here
# means a quoted string that spans lines is still seen as ONE quoted span rather than two broken
# ones. The awk program is fed a single line, so `#` runs only to the next `;`, never to the end of
# a multi-line script.
#
# `sq`/`dq`/`bs` are built with sprintf because the program itself is single-quoted in shell and so
# cannot contain a literal `'`.
clean=$(printf '%s' "$cmd" | tr '\n' ';' | awk '
BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34); bs = sprintf("%c", 92) }
{
  out = ""; q = ""; n = length($0); i = 1
  while (i <= n) {
    c = substr($0, i, 1)
    if (q == "") {
      if (c == bs)            { out = out " "; i += 2; continue }
      if (c == sq || c == dq) { q = c; out = out " "; i++; continue }
      if (c == "#")           { while (i <= n && substr($0, i, 1) != ";") i++; continue }
      out = out c; i++
    } else {
      if (q == dq && c == bs) { i += 2; continue }
      if (c == q)             { q = "" }
      i++
    }
  }
  if (q != "") { exit 3 }
  print out
}' 2>/dev/null) || exit 0

# ------------------------------------------------------------------------- the guard recognition
# A line that calls one of the kit's guards is the thing this hook exists to encourage, so the whole
# line is allowed. The hook sees one command string and cannot see the guard's own inner `git` —
# which is fine, because the guard is precisely what it wants to have run.
#
# Checked on the RAW command, not the stripped one, and that is deliberate. Every skill spells the
# call `"$GUARDS/guarded-commit.sh" …`, so the guard's own name lives inside a quoted span and the
# stripper would delete it — turning the prescribed call into an unrecognised one. The cost is that
# `echo "guarded-commit.sh"` sitting on the same line as a real bare `git commit` would whitelist
# it; that is an over-recognition, which fails OPEN, and this hook's whole declared direction (see
# ADR 0002) is that over-allowing is the mistake it is willing to make.
case "$cmd" in
  *guarded-commit.sh*|*guarded-push.sh*|*guarded-pr-merge.sh*|*guarded-merge.sh*) exit 0 ;;
esac

# ------------------------------------------------------------------------------- the deny output
deny() { # $1 the offending segment  $2 the replacement sentence
  local reason
  reason="Blocked by the git write-gate: \`$1\` is one of the writes that produced #26 and #280 in a shared checkout.
$2
Set GIT_GATE=off to disable this gate for one command or for the session."
  jq -n --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}

# --------------------------------------------------------------------------------- the probe
# A denial names a `guarded-*.sh` replacement, so the gate must not deny where that replacement
# cannot exist. A repository carrying a committed `.claude/skills/repo-profile.md` has opted into
# `create-issue`/`implement-issue`/`merge-pr` and therefore HAS those guards to route to; a
# repository without one gets no denial, ever. This is exactly the role the `dnx` probe plays for
# `roseline-gate.sh` (#112): never deny in favour of a replacement that cannot apply here.
#
# From a linked worktree the profile is present because it is tracked (#157) — which is precisely
# when the guards matter most. `GIT_GATE=on` short-circuits it, the same way `ROSELINE_GATE=on`
# does: the user is the only authority this hook can consult about a repo it cannot recognise.
is_profiled() { # $1 a directory
  local dir="$1" top
  [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -f "$top/.claude/skills/repo-profile.md" ]
}

# ------------------------------------------------------------------- judge one command segment
judge() { # $1 one segment of the stripped command
  local seg="$1" seg_dir="" sub=""
  # Word splitting is the tokeniser; `set -f` above is what makes it safe.
  set -- $seg
  [ $# -gt 0 ] || return 0

  # Prefixes that carry a command rather than being one: `env FOO=1 git …`, `sudo git …`,
  # `TZ=UTC git …`. Anything else stops the walk — the segment simply is not a git invocation.
  while [ $# -gt 0 ]; do
    case "$1" in
      env|sudo|command|nohup|time) shift ;;
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  case "$1" in git|*/git) shift ;; *) return 0 ;; esac

  # git's OWN options, before the subcommand — including the `git -c user.email=… -c user.name=… commit`
  # shape the kit's own guards emit, which a naive "second word is the subcommand" reader would miss
  # entirely. `-C <path>` is captured, because it names the repository this segment acts on and it
  # OUTRANKS the payload's cwd (a `git -C <profiled-repo> push` run from anywhere is still that
  # repo's push).
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) [ $# -ge 2 ] || return 0; seg_dir="$2"; shift 2 ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        [ $# -ge 2 ] || return 0; shift 2 ;;
      --*=*) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  sub="$1"; shift

  # Nothing below is worth a probe, so the probe runs only once a git subcommand is in hand.
  case "$sub" in
    checkout|restore|reset|clean|push|commit|merge) ;;
    *) return 0 ;;
  esac

  if [ "$FORCE" != 1 ]; then
    local dir="$seg_dir"
    [ -n "$dir" ] || dir="$cwd"
    case "$dir" in /*) ;; *) dir="${cwd:-.}/$dir" ;; esac
    is_profiled "$dir" || return 0
  fi

  local a
  case "$sub" in
    checkout)
      # A pathspec of `.` is the whole tree, with or without a ref and with or without `--`.
      # `git checkout <branch>` and `git checkout -- <named path>` are scoped and stay allowed.
      for a in "$@"; do
        [ "$a" = "." ] && deny "$seg" \
          "That discards every uncommitted change in the tree. Use \`git checkout -- <path>\` for the one file you mean, or commit through \`skills/implement-issue/scripts/guarded-commit.sh\` first."
      done
      ;;
    restore)
      for a in "$@"; do
        [ "$a" = "." ] && deny "$seg" \
          "That discards every uncommitted change in the tree. Use \`git restore <path>\` for the one file you mean."
      done
      ;;
    reset)
      for a in "$@"; do
        [ "$a" = "--hard" ] && deny "$seg" \
          "That throws away the working tree, including another agent's uncommitted work in a shared checkout. Use \`git reset --keep\`, or give each branch its own worktree with \`skills/implement-issue/scripts/make-worktree.sh\`."
      done
      ;;
    clean)
      for a in "$@"; do
        case "$a" in
          --force) deny "$seg" "That deletes untracked files irreversibly. Use \`git clean -n\` to look first, or \`git stash -u\` to keep them." ;;
          --*) ;;
          -*f*) deny "$seg" "That deletes untracked files irreversibly. Use \`git clean -n\` to look first, or \`git stash -u\` to keep them." ;;
        esac
      done
      ;;
    push)
      # `--force-with-lease` is NOT `--force`: it is allowed, but only on a line that also invokes
      # the guard (which asserted the branch first) — and such a line already returned above.
      for a in "$@"; do
        case "$a" in
          --force|-f) deny "$seg" \
            "A forced push overwrites whatever the remote holds, which in a shared checkout is another agent's branch. Use \`skills/implement-issue/scripts/guarded-push.sh -C <worktree> <branch> -- --force-with-lease\`." ;;
        esac
      done
      deny "$seg" \
        "A bare push does not check which branch it is pushing — that is how #26 landed a commit in another agent's PR with exit 0. Use \`skills/implement-issue/scripts/guarded-push.sh -C <worktree> <branch>\`, which reads the remote back afterwards."
      ;;
    commit)
      deny "$seg" \
        "A bare commit does not check which branch HEAD is on — that is how #26 and #280 landed work on someone else's branch with exit 0. Use \`skills/implement-issue/scripts/guarded-commit.sh -C <worktree> <branch> -- <git commit args>\`."
      ;;
    merge)
      # `--abort`/`--continue`/`--quit` finish or unwind a merge that is already in progress; they
      # are not the write the guard exists for.
      for a in "$@"; do
        case "$a" in --abort|--continue|--quit) return 0 ;; esac
      done
      deny "$seg" \
        "A merge is the largest single write in the lifecycle and the one with the widest window (#41). Use \`skills/implement-issue/scripts/guarded-merge.sh -C <worktree> <branch> -- <ref>\`."
      ;;
  esac
  return 0
}

# ------------------------------------------------------------------------------ the segment walk
# `;`, `&&`, `||`, `|`, `&` and newline all separate commands; `&&`/`||` simply yield an extra empty
# segment, which the walk skips. A here-string, not a pipe: the loop has to run in THIS shell so
# `deny`'s `exit 0` ends the hook rather than a subshell.
segments=$(printf '%s' "$clean" | tr ';|&' '\n\n\n')
while IFS= read -r segment; do
  case "$segment" in *[!\ ]*) ;; *) continue ;; esac
  judge "$segment"
done <<EOF
$segments
EOF

exit 0
