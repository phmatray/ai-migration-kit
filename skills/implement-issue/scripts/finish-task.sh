#!/usr/bin/env bash
# finish-task.sh — close one plan task in ONE call: commit through the guard, tick the task's
# checkboxes on the issue plan (and its `- [ ] Task <k>` line in the PR's `### Plan` mirror), push
# through the guard.
#
# Why (#499): implement-issue Step 6 closed a task in four to six tool turns — edit the plan file
# per line, edit the PR mirror, tick-plan.sh, gh pr edit, guarded-commit.sh, guarded-push.sh — and
# every turn re-reads the whole context. Measured average: 127 turns per run. This is the same
# sequence, in the same order Step 6 prescribes (commit → tick → mirror → push), in one turn.
#
# It composes the existing guards and never bypasses one: the commit goes through
# guarded-commit.sh, the issue write through tick-plan.sh (fail-closed, read-back verified), the
# push through guarded-push.sh. Each stage's exit code is this script's exit code, prefixed with
# the stage name, so a resume knows where to pick up; a stage already done is skipped, not redone
# (nothing to commit → "already committed"; no unticked box in the task → "already ticked").
#
# Usage:
#   finish-task.sh --repo <[host/]owner/repo> --issue <n> --task <k> --worktree <dir> --branch <name>
#                  [--pr <n>] [--comment-id <id>] [-c key=value]… [-m <message>] [--dry-run]
#
#   --repo        OWNER/REPO, or HOST/OWNER/REPO for a GitHub Enterprise host. The host is resolved
#                 once, by skills/_shared/scripts/_gh-host.sh (#514), and tick-plan.sh inherits it
#   --task        the `### Task <k>` block whose `- [ ]` lines are flipped — only that block
#   --pr          the PR whose body carries the `### Plan` mirror; omitted → the mirror is skipped
#   --comment-id  the plan lives in that comment, not the issue body (older issues)
#   -c            forwarded to guarded-commit.sh (commit identity), repeatable
#   -m            the commit message; default: the task's last step, `Commit: \`…\``
#   --dry-run     print what each stage would do; write nothing anywhere
#
# Exit: 0 all stages done or already done · 64 usage · 65 task not found / no message ·
#       otherwise the failing stage's own exit code, named on stderr.

set -euo pipefail

TOOL="finish-task"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }
refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

REPO=""; ISSUE=""; TASK=""; WORKTREE=""; BRANCH=""; PR=""; COMMENT_ID=""; MSG=""; DRY=""
CONFIG=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       REPO="${2:?}"; shift 2 ;;
    --issue)      ISSUE="${2:?}"; shift 2 ;;
    --task)       TASK="${2:?}"; shift 2 ;;
    --worktree)   WORKTREE="${2:?}"; shift 2 ;;
    --branch)     BRANCH="${2:?}"; shift 2 ;;
    --pr)         PR="${2:?}"; shift 2 ;;
    --comment-id) COMMENT_ID="${2:?}"; shift 2 ;;
    -c)           CONFIG+=(-c "${2:?}"); shift 2 ;;
    -m)           MSG="${2:?}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            refuse "unknown argument: $1" ;;
  esac
done
[ -n "$REPO" ] && [ -n "$ISSUE" ] && [ -n "$TASK" ] && [ -n "$WORKTREE" ] && [ -n "$BRANCH" ] \
  || refuse "--repo, --issue, --task, --worktree and --branch are all required"
case "$TASK" in *[!0-9]*|"") refuse "--task takes the task number, got '$TASK'" ;; esac

# The repository's own host (#514): `gh api` never infers one and `gh -R OWNER/REPO` takes gh's
# default, so on a GitHub Enterprise repository every call below reached github.com. Decided in ONE
# place, before the first gh call. The exported GH_HOST reaches every call below and tick-plan.sh,
# which is handed the normalised OWNER/REPO and keeps the host it inherits.
# CALLABLE, not merely readable: an empty or truncated helper sources cleanly and defines nothing.
GH_HOST_LIB="$HERE/../../_shared/scripts/_gh-host.sh"
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve >/dev/null 2>&1 \
  || { echo "$TOOL: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2; exit 64; }
gh_host_resolve "$REPO" || exit 64
REPO="$KIT_REPO_SLUG"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- the flip: only `### Task <k>`'s block, only its `- [ ]` lines -------------------------------
flip_task() {  # flip_task <in> <out> ; prints the number of boxes flipped
  awk -v k="$TASK" '
    /^### Task [0-9]+/ { n = $3; sub(/:.*/, "", n); inblock = (n == k) }
    /^## / { inblock = 0 }
    inblock && /^[ \t]*- \[ \]/ { sub(/- \[ \]/, "- [x]"); cnt++ }
    { print }
    END { printf "%d", cnt > "/dev/stderr" }
  ' "$1" > "$2" 2>"$WORK/flipped"
  cat "$WORK/flipped"
}
task_present() { grep -qE "^### Task ${TASK}([: ]|$)" "$1"; }

# --- stage 0: the plan, and the message ---------------------------------------------------------
if [ -n "$COMMENT_ID" ]; then endpoint="repos/$REPO/issues/comments/$COMMENT_ID"; else endpoint="repos/$REPO/issues/$ISSUE"; fi
gh api "$endpoint" --jq .body > "$WORK/plan.orig.md" \
  || { echo "$TOOL: plan: could not read $endpoint" >&2; exit 1; }
task_present "$WORK/plan.orig.md" \
  || { echo "$TOOL: plan: no '### Task $TASK' block in the plan (issue #$ISSUE${COMMENT_ID:+, comment $COMMENT_ID})" >&2; exit 65; }
flipped=$(flip_task "$WORK/plan.orig.md" "$WORK/plan.md")

if [ -z "$MSG" ]; then
  # The task's last step reads `- [ ] **Step N:** Commit: `<message>`` — the plan shape's contract.
  MSG=$(awk -v k="$TASK" '
    /^### Task [0-9]+/ { n = $3; sub(/:.*/, "", n); inblock = (n == k) }
    /^## / { inblock = 0 }
    inblock && /^[ \t]*- \[[ x]\].*Commit:/ { line = $0 }
    END { if (line != "") { sub(/.*Commit:[ \t]*`/, "", line); sub(/`.*$/, "", line); print line } }
  ' "$WORK/plan.orig.md")
  [ -n "$MSG" ] || { echo "$TOOL: message: Task $TASK has no 'Commit: \`…\`' step — pass -m" >&2; exit 65; }
fi

if [ -n "$DRY" ]; then
  echo "$TOOL: dry-run — would commit on $BRANCH in $WORKTREE with: $MSG"
  echo "$TOOL: dry-run — would flip $flipped box(es) of Task $TASK on $endpoint${PR:+ and mirror them on PR #$PR}"
  echo "$TOOL: dry-run — would push $BRANCH"
  exit 0
fi

# --- stage 1: commit (skipped when the tree is clean — already committed on a previous run) ------
if git -C "$WORKTREE" diff --quiet && git -C "$WORKTREE" diff --cached --quiet \
   && [ -z "$(git -C "$WORKTREE" ls-files --others --exclude-standard)" ]; then
  echo "$TOOL: commit: nothing to commit — already committed"
else
  git -C "$WORKTREE" add -A
  "$HERE/guarded-commit.sh" -C "$WORKTREE" "${CONFIG[@]+"${CONFIG[@]}"}" "$BRANCH" -- -m "$MSG" \
    || { rc=$?; echo "$TOOL: commit: guarded-commit.sh exited $rc" >&2; exit "$rc"; }
fi

# --- stage 2: tick the issue plan through tick-plan.sh (fail-closed) ----------------------------
if [ "$flipped" -eq 0 ]; then
  echo "$TOOL: tick: Task $TASK has no unticked box — already ticked"
else
  "$HERE/tick-plan.sh" --repo "$REPO" --issue "$ISSUE" ${COMMENT_ID:+--comment-id "$COMMENT_ID"} \
      --before "$WORK/plan.orig.md" --after "$WORK/plan.md" \
    || { rc=$?; echo "$TOOL: tick: tick-plan.sh exited $rc" >&2; exit "$rc"; }
fi

# --- stage 3: the PR's `### Plan` mirror — one `- [ ] Task <k>: <name>` line per task (Step 5) ----
if [ -n "$PR" ]; then
  gh pr view "$PR" --repo "$REPO" --json body --jq .body > "$WORK/pr.orig.md" \
    || { echo "$TOOL: mirror: could not read PR #$PR" >&2; exit 1; }
  if grep -qE "^[[:space:]]*- \[[ x]\] Task ${TASK}([: ]|\$)" "$WORK/pr.orig.md"; then
    if grep -qE "^[[:space:]]*- \[ \] Task ${TASK}([: ]|\$)" "$WORK/pr.orig.md"; then
      sed -E "s/^([[:space:]]*)- \[ \] Task ${TASK}([: ]|\$)/\1- [x] Task ${TASK}\2/" "$WORK/pr.orig.md" > "$WORK/pr.md"
      [ -s "$WORK/pr.md" ] || { echo "$TOOL: mirror: refusing to write an empty PR body" >&2; exit 1; }
      gh pr edit "$PR" --repo "$REPO" --body-file "$WORK/pr.md" >/dev/null \
        || { rc=$?; echo "$TOOL: mirror: gh pr edit exited $rc" >&2; exit "$rc"; }
      echo "$TOOL: mirror: PR #$PR — Task $TASK ticked"
    else
      echo "$TOOL: mirror: PR #$PR already shows Task $TASK ticked"
    fi
  else
    echo "$TOOL: mirror: PR #$PR carries no 'Task $TASK' line under ### Plan — mirror skipped (resync it per Step 6)"
  fi
fi

# --- stage 4: push through the guard -------------------------------------------------------------
"$HERE/guarded-push.sh" -C "$WORKTREE" "$BRANCH" \
  || { rc=$?; echo "$TOOL: push: guarded-push.sh exited $rc" >&2; exit "$rc"; }
echo "$TOOL: Task $TASK closed — committed, ticked ($flipped box(es))${PR:+, mirrored}, pushed"
