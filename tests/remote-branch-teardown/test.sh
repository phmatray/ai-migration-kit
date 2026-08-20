#!/usr/bin/env bash
# Golden test for merge-pr's remote-branch-teardown.sh (#185).
#
# Step 7 used to assume the remote head branch was already gone by the time it ran — via Step 5's
# `--delete-branch` or the repo's own `delete_branch_on_merge` — and never checked. On a repo
# without that setting on, and on the kit's own layout (the branch lives in an `implement-issue`
# worktree, so gh's local delete fails first and short-circuits before it ever reaches the remote
# side — confirmed by reading `mergeRun` in `cli/cli`, Task 1 of #185), that assumption is false:
# `origin/<headRefName>` leaks permanently and nothing ever notices.
#
# remote-branch-teardown.sh is not fixture-file driven — it shells out to `git ls-remote` and
# `gh api -X DELETE`, so this suite stubs both (same idiom as tests/guarded-git/test.sh) rather than
# feeding it JSON. Three shapes from the issue's own Task 3, plus the race the script itself
# documents tolerating (a concurrent delete winning between the ls-remote and the DELETE call) and
# the two refusal paths (bad usage, a genuine ls-remote failure).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

SCRIPT="$KIT_ROOT/skills/merge-pr/scripts/remote-branch-teardown.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing or not executable"; exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

STUBS=$(kit_scratch)
GIT_OUT="$STUBS/git-ls-remote.out"
GIT_RC="$STUBS/git-ls-remote.rc"
GH_OUT="$STUBS/gh-delete.out"
GH_RC="$STUBS/gh-delete.rc"
GH_CALLED="$STUBS/gh-called"

# Stubs read their behaviour from the four files above rather than from arguments baked into the
# script text — so a case only has to rewrite the files, never regenerate the stub. Absolute paths
# are baked in at write time (the heredoc is deliberately unquoted); $STUBS never contains a quote
# or a `$`, since kit_scratch built it with mktemp.
cat > "$STUBS/git" <<STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "ls-remote" ]; then
  cat "$GIT_OUT" 2>/dev/null
  exit "\$(cat "$GIT_RC")"
fi
echo "unexpected git invocation in remote-branch-teardown suite: \$*" >&2
exit 99
STUBEOF
chmod +x "$STUBS/git"

cat > "$STUBS/gh" <<STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then
  : > "$GH_CALLED"
  cat "$GH_OUT" >&2 2>/dev/null
  exit "\$(cat "$GH_RC")"
fi
echo "unexpected gh invocation in remote-branch-teardown suite: \$*" >&2
exit 99
STUBEOF
chmod +x "$STUBS/gh"

BRANCH="fix/185-remote-branch-teardown"
REPO="phmatray/ai-migration-kit"

# set_git <ls-remote stdout+stderr> <exit code>
set_git() { printf '%s' "$1" > "$GIT_OUT"; printf '%s' "$2" > "$GIT_RC"; }
# set_gh <api stdout+stderr> <exit code>
set_gh()  { printf '%s' "$1" > "$GH_OUT";  printf '%s' "$2" > "$GH_RC"; }

# run_case <name> <want-exit> <what> [gh-must-not-be-called]
run_case() {
  local name="$1" want_exit="$2" what="$3" forbid_gh="${4:-}"
  local out rc=0
  rm -f "$GH_CALLED"
  out=$(PATH="$STUBS:$PATH" "$SCRIPT" "$BRANCH" "$REPO" 2>&1) || rc=$?
  CASE_OUT="$out"
  if [ "$rc" != "$want_exit" ]; then
    note_fail "$name — $what
      want exit: $want_exit
      got exit:  $rc
      output: $out"
    return 1
  fi
  if [ -n "$forbid_gh" ] && [ -e "$GH_CALLED" ]; then
    note_fail "$name — $what
      gh api was called, but the remote branch was already gone — no delete was owed
      output: $out"
    return 1
  fi
  return 0
}

want_stdout() {
  local name="$1" want="$2" what="$3"
  if [ "$CASE_OUT" != "$want" ]; then
    note_fail "$name — $what
      want stdout: $want
      got:         $CASE_OUT"
    return 1
  fi
  return 0
}

want_contains() {
  local name="$1" needle="$2" what="$3"
  if ! printf '%s' "$CASE_OUT" | grep -qF -- "$needle"; then
    note_fail "$name — $what
      want output to contain: $needle
      got: $CASE_OUT"
    return 1
  fi
  return 0
}

# --- 1. remote branch already gone: a pure no-op, and gh must never be dialed for a delete that
# isn't owed (Step 5's --delete-branch or delete_branch_on_merge already did it).
set_git "" 0
set_gh "gh should not have been called" 99
if run_case already-gone 0 'the branch is already gone on origin — no-op, no DELETE call' forbid_gh; then
  want_stdout already-gone already-gone \
    'prints the exact word already-gone so a caller can branch on it' \
  && echo "ok: already-gone — no-op, gh never dialed"
fi

# --- 2. remote branch present, deletion succeeds: the routine leaked-branch case this issue exists
# to close (the kit's worktree layout makes gh's own --delete-branch fail before it gets here).
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "" 0
if run_case present-deleted 0 'the branch survived the merge and the DELETE call succeeds'; then
  want_stdout present-deleted deleted \
    'prints the exact word deleted' \
  && echo "ok: present-deleted — survives, gets deleted"
fi

# --- 3. remote branch present, delete fails for real (permissions, rate limit, a genuine API
# error) — must be reported on stderr, never swallowed as if it were "already gone".
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 500: Internal Server Error" 1
if run_case present-delete-fails 1 'a real DELETE failure is reported, not silently swallowed'; then
  want_contains present-delete-fails "failed to delete origin/$BRANCH" \
    'names the branch that could not be torn down' \
  && want_contains present-delete-fails "HTTP 500" \
    "carries the API's own error text so a human can act on it" \
  && echo "ok: present-delete-fails — reported, not swallowed"
fi

# --- 4/5. the race the script documents tolerating: a concurrent delete_branch_on_merge or a slow
# --delete-branch wins between the ls-remote check and this call. gh's own deleteRemoteBranch
# tolerates a 422 OR a 404 "Reference does not exist" the same way; both must read as already-gone.
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 422: Validation Failed - Reference does not exist" 1
if run_case race-422 0 'a 422 "Reference does not exist" mid-race is tolerated, not a failure'; then
  want_stdout race-422 already-gone \
    'the race resolves to already-gone, same as the no-op path' \
  && echo "ok: race-422 — concurrent delete tolerated"
fi

set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 404: Not Found" 1
if run_case race-404 0 'a bare 404 mid-race is tolerated the same as a 422'; then
  want_stdout race-404 already-gone \
    'the race resolves to already-gone regardless of which of the two codes gh returns' \
  && echo "ok: race-404 — concurrent delete tolerated"
fi

# --- 6. git ls-remote itself fails (network, auth) — a real failure, and gh must never be dialed
# on top of an unknown remote state.
set_git "fatal: unable to access 'https://github.com/$REPO/': Could not resolve host" 1
set_gh "gh should not have been called" 99
if run_case ls-remote-fails 1 'git ls-remote failing is reported, and gh is never dialed on top of it' forbid_gh; then
  want_contains ls-remote-fails "git ls-remote --heads origin '$BRANCH' failed" \
    'names the command that failed, not just "something went wrong"' \
  && want_contains ls-remote-fails "Could not resolve host" \
    "carries git's own error text" \
  && echo "ok: ls-remote-fails — reported, gh never dialed"
fi

# --- 7. usage error: a script/prerequisite failure, distinct from every teardown outcome above —
# exit 2, never 0 or 1, so a caller can tell "called wrong" apart from "ran and something leaked".
out=$(PATH="$STUBS:$PATH" "$SCRIPT" 2>&1) && rc=0 || rc=$?
if [ "$rc" != 2 ]; then
  note_fail "usage — missing arguments must exit 2, got $rc: $out"
elif ! printf '%s' "$out" | grep -qF 'usage:'; then
  note_fail "usage — exit 2 but no usage line: $out"
else
  echo "ok: usage — missing arguments exit 2 with a usage line"
fi

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "remote-branch-teardown: FAILED"
  exit 1
fi
echo
echo "remote-branch-teardown: OK — already-gone is a no-op, a survivor gets deleted, a real"
echo "failure is reported, the delete_branch_on_merge race is tolerated, and bad input exits 2."
