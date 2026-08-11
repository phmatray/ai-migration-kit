#!/usr/bin/env bash
# tests/_lib.sh — the golden suites' shared preamble. SOURCED, never executed.
#
# Why this file exists (#72). Four suites each carried their own scratch directory, their own EXIT
# trap and their own copy of the samples/ immutability check — including their own restatement of
# the invariant that `local rc=$?` must be the FIRST statement in the handler. Anything before it
# overwrites the status being reported, which turns a failing suite into a silent green: the one
# outcome worse than a red one.
#
# That is the same hazard tests/xunit-v3/test.sh §8 was written to prevent for the importlib
# loader — an invisible, load-bearing prefix that a copy-paste drops with no symptom — applied to
# the trap handler instead. #42 gave the loader one home; this gives the trap one.
#
# They had already diverged before this landed, which is the usual first sign. Measured on the four
# suites at the time of writing:
#
#     suite              scratch      samples/ check   __pycache__   other
#     audit-inventory    $scratch     yes              no (argued)   —
#     ci-template        $scratch     yes              no            hashes the template
#     renovate-config    $scratch     NO               no            —
#     xunit-v3           ${scratch:-} yes              yes           —
#
# Three spellings of one check, one suite silently missing it, and two spellings of the same
# guard against an unset variable.
#
# ---------------------------------------------------------------------------------- the contract
#
#   kit_init <kit-root>
#       Arm the EXIT trap. Call once, after the suite's `cd` to the kit root, before any work.
#
#   kit_scratch
#       Print a fresh scratch directory, removed at exit. Call as often as needed, including from
#       a command substitution — see kit_init for why that is not the trap it looks like.
#
#   kit_guard <function-name>
#       Register an extra assertion to run at exit, after the scratch dirs are removed. The
#       function prints its own FAIL message and returns non-zero to fail the run. This is how a
#       suite adds what only it cares about — the template hash, the __pycache__ check — WITHOUT
#       re-implementing the handler around it.
#
#   kit_guard_samples_unchanged
#       The check every suite that builds anything wants: samples/ must come out untouched. Not
#       registered automatically — a suite says so, because "forgot to call it" and "decided it
#       does not apply" must not look the same. That ambiguity is exactly how renovate-config ended
#       up without it.
#
#   any_match <find-args…>
#       `find` that answers a yes/no question without tripping SIGPIPE. `find … | grep -q .` exits
#       141 under `pipefail` when grep closes the pipe early, and the caller's `if` then reads the
#       failure as "found nothing" — an intermittently disabled guard (#48).
#
# There is deliberately no `set -euo pipefail` here: the callers set it, and re-setting it in a
# sourced file would mean this file silently decides the shell options of every suite that loads it
# (the reason skills/implement-issue/scripts/_assert-branch.sh gives for the same omission).

KIT_LIB_ROOT=""
KIT_LIB_TMP=""
KIT_LIB_GUARDS=()

kit_init() {
  KIT_LIB_ROOT="${1:?kit_init needs the kit root}"
  # ONE parent directory, created here, removed whole at exit. Every scratch dir is a child of it.
  #
  # The obvious design — `kit_scratch` appends to an array — is broken in a way that is invisible
  # at the call site: suites write `s=$(kit_scratch)`, and command substitution runs the function
  # in a SUBSHELL, so the append lands in a copy of the array that dies with it. The parent never
  # learns the directory exists and never removes it. Caught by tests/lib/test.sh section 2 the
  # first time it ran; a suite would only ever have shown it as a slow leak of /tmp entries.
  #
  # A parent directory has no such failure mode: the child is created inside a path the parent
  # already knows, so nothing has to be communicated back out of the subshell.
  KIT_LIB_TMP=$(mktemp -d)
  kit_require_find_quit
  trap kit_cleanup EXIT
}

kit_scratch() {
  mktemp -d "${KIT_LIB_TMP:?kit_scratch called before kit_init}/scratch.XXXXXX"
}

kit_guard() {
  KIT_LIB_GUARDS+=("${1:?kit_guard needs a function name}")
}

kit_cleanup() {
  # FIRST statement, always. A `rm`, an `echo`, even a `local d` with a command substitution in it
  # would replace the status this handler exists to report.
  local rc=$?
  local g
  [ -n "$KIT_LIB_TMP" ] && rm -rf "$KIT_LIB_TMP"
  for g in ${KIT_LIB_GUARDS+"${KIT_LIB_GUARDS[@]}"}; do
    if ! "$g"; then
      exit 1
    fi
  done
  exit "$rc"
}

kit_guard_samples_unchanged() {
  local dirty
  dirty=$(git -C "$KIT_LIB_ROOT" status --porcelain -- samples/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FAIL: the committed fixture was mutated — a suite must not write to samples/:"
    echo "$dirty"
    return 1
  fi
}

any_match() {
  # `-print -quit` rather than a pipe: find stops itself on the first hit, so nothing can close the
  # pipe under it. Captured into a variable so the exit status describes the SEARCH and not the
  # reader's early exit — the defect #48 pinned, where a SIGPIPE'd find returned 141 and `pipefail`
  # promoted it to the pipeline's status, making "found something" read as "found nothing".
  #
  # `|| true` is load-bearing, not sloppiness: find exits non-zero on a path that legitimately does
  # not exist, and a bare assignment under `set -e` would abort the caller — for a guard registered
  # with kit_guard that means aborting on EVERY exit path, including the successful one.
  local hit
  hit=$(find "$@" -print -quit 2>/dev/null || true)
  [ -n "$hit" ]
}

kit_require_find_quit() {
  # `-print -quit` is what makes any_match safe, so prove this host's find HAS it — once, loudly.
  # Otherwise the `|| true` above cuts both ways: on a find without `-quit` (busybox, some minimal
  # containers) every call answers "nothing found" with the error discarded, and a guard leaning on
  # any_match reports clean from the very first exit path. A silent "clean" is what lets a stray
  # .pyc reach the tree.
  if ! find "${KIT_LIB_ROOT:-.}" -maxdepth 0 -print -quit >/dev/null 2>&1; then
    echo "FAIL: this host's find does not support '-print -quit', which any_match depends on."
    echo "      Every any_match() call would answer 'nothing found' regardless of what is there."
    exit 1
  fi
}
